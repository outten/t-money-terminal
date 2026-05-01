require 'json'
require 'fileutils'
require 'date'
require 'securerandom'
require_relative 'tax_lot'

# PortfolioStore — multi-lot, file-backed portfolio at `data/portfolio.json`.
#
# A "lot" is a single buy event with its own cost basis and acquired_at:
#
#   { id:, symbol:, shares:, cost_basis:, acquired_at: (ISO date|nil),
#     notes:, created_at: (ISO timestamp), closed_at: (nil until sold) }
#
# Multiple lots per symbol are normal — investors typically buy in tranches.
# The aggregated "position" (one row per symbol, sum shares, weighted-avg
# cost basis) is computed on read by `find`/`positions`.
#
# Closes happen via `close_shares_fifo`, which walks open lots oldest-first,
# splitting the last lot if it's only partially closed, and records realized
# P&L per closed lot. Storing closed lots inline (rather than deleting them)
# keeps the audit trail intact — the trade history (TradesStore) references
# closed lots by id.
#
# Mutations acquire MUTEX; persistence uses an atomic rename-over-tmp.
module PortfolioStore
  DEFAULT_PATH = File.expand_path('../../data/portfolio.json', __FILE__)
  MUTEX        = Mutex.new

  module_function

  def path
    ENV['PORTFOLIO_PATH'] || DEFAULT_PATH
  end

  # Returns the full lot list (open + closed). Tests mostly want this.
  # Backwards-compatible with the legacy single-row-per-symbol shape: any row
  # missing :id gets one assigned at read time, and missing :closed_at is nil.
  def read
    list = read_unlocked
    list
  end

  def open_lots
    read.reject { |lot| lot[:closed_at] }
  end

  def lots_for(symbol)
    sym = symbol.to_s.upcase
    open_lots.select { |lot| lot[:symbol] == sym }
  end

  def symbols
    open_lots.map { |lot| lot[:symbol] }.uniq
  end

  # Aggregated open positions, one row per symbol:
  #   { symbol:, shares:, cost_basis:, lots: [...] }
  # cost_basis is the weighted-average across the symbol's open lots.
  def positions
    open_lots.group_by { |lot| lot[:symbol] }.map do |sym, lots|
      total_shares    = lots.sum { |l| l[:shares].to_f }
      total_cost      = lots.sum { |l| l[:shares].to_f * l[:cost_basis].to_f }
      weighted_basis  = total_shares > 0 ? (total_cost / total_shares) : 0.0
      earliest_acq    = lots.map { |l| l[:acquired_at] }.compact.min
      {
        symbol:      sym,
        shares:      total_shares.round(6),
        cost_basis:  weighted_basis.round(4),
        acquired_at: earliest_acq,
        lots:        lots,
        notes:       lots.map { |l| l[:notes] }.compact.uniq.join(' · ').then { |s| s.empty? ? nil : s }
      }
    end.sort_by { |p| p[:symbol] }
  end

  # Single aggregated position for a symbol, or nil if no open lots.
  def find(symbol)
    sym = symbol.to_s.upcase
    positions.find { |p| p[:symbol] == sym }
  end

  # Append a new lot. Returns the saved hash (with generated id + created_at).
  # Raises ArgumentError on invalid input.
  def add_lot(symbol:, shares:, cost_basis:, acquired_at: nil, notes: nil)
    sym = symbol.to_s.strip.upcase
    raise ArgumentError, 'symbol required' if sym.empty?

    sh = Float(shares) rescue nil
    raise ArgumentError, 'shares must be a positive number' if sh.nil? || sh <= 0

    cb = Float(cost_basis) rescue nil
    raise ArgumentError, 'cost_basis must be a positive number' if cb.nil? || cb <= 0

    lot = {
      id:          SecureRandom.hex(6),
      symbol:      sym,
      shares:      sh.round(6),
      cost_basis:  cb.round(4),
      acquired_at: normalize_date(acquired_at),
      notes:       notes.to_s.strip.empty? ? nil : notes.to_s.strip,
      created_at:  Time.now.utc.iso8601,
      closed_at:   nil
    }

    MUTEX.synchronize do
      list = read_unlocked
      list << lot
      write_unlocked(list)
    end
    lot
  end

  # Close `shares` of `symbol` at `price`, FIFO across open lots. Returns:
  #   { symbol:, shares_closed:, price:, sold_at:, realized_pl:,
  #     lots_closed: [{lot_id:, shares:, cost_basis:, realized_pl:}, ...] }
  # Raises ArgumentError if shares > total open shares for the symbol.
  def close_shares_fifo(symbol:, shares:, price:, sold_at: nil)
    sym = symbol.to_s.strip.upcase
    raise ArgumentError, 'symbol required' if sym.empty?

    requested = Float(shares) rescue nil
    raise ArgumentError, 'shares must be a positive number' if requested.nil? || requested <= 0

    px = Float(price) rescue nil
    raise ArgumentError, 'price must be a positive number' if px.nil? || px <= 0

    sold_iso = normalize_date(sold_at) || Date.today.iso8601

    MUTEX.synchronize do
      list = read_unlocked

      # Open lots for this symbol, oldest-first by acquired_at then created_at.
      open = list.each_with_index
                 .select { |lot, _i| lot[:symbol] == sym && lot[:closed_at].nil? }

      total_open = open.sum { |lot, _| lot[:shares].to_f }
      if requested > total_open + 1e-9
        raise ArgumentError, "cannot sell #{requested} shares; only #{total_open} open in #{sym}"
      end

      remaining = requested
      lots_closed = []
      now_iso = Time.now.utc.iso8601

      open.sort_by { |lot, _i| [lot[:acquired_at] || '', lot[:created_at]] }.each do |lot, idx|
        break if remaining <= 1e-9

        if lot[:shares] <= remaining + 1e-9
          # Fully close this lot.
          shares_closed = lot[:shares]
          pl = ((px - lot[:cost_basis]) * shares_closed).round(2)
          tax = TaxLot.classify(lot: lot, sold_at: sold_iso)
          list[idx] = lot.merge(closed_at: now_iso, closed_price: px.round(4), closed_sold_at: sold_iso, realized_pl: pl)
          lots_closed << {
            lot_id:                lot[:id],
            shares:                shares_closed,
            cost_basis:            lot[:cost_basis],
            realized_pl:           pl,
            holding_period:        tax[:holding_period],
            days_held:             tax[:days_held],
            acquired_at_effective: tax[:acquired_at_effective],
            acquired_at_source:    tax[:source]
          }
          remaining -= shares_closed
        else
          # Partial close: split into a closed sub-lot + remaining open lot.
          shares_closed = remaining
          remaining_shares = (lot[:shares] - shares_closed).round(6)
          pl = ((px - lot[:cost_basis]) * shares_closed).round(2)
          tax = TaxLot.classify(lot: lot.merge(shares: shares_closed), sold_at: sold_iso)

          closed_sub = lot.merge(
            id:             SecureRandom.hex(6),
            shares:         shares_closed.round(6),
            closed_at:      now_iso,
            closed_price:   px.round(4),
            closed_sold_at: sold_iso,
            realized_pl:    pl,
            split_from:     lot[:id]
          )
          remaining_open = lot.merge(shares: remaining_shares)
          list[idx] = remaining_open
          list << closed_sub
          lots_closed << {
            lot_id:                closed_sub[:id],
            shares:                shares_closed,
            cost_basis:            lot[:cost_basis],
            realized_pl:           pl,
            holding_period:        tax[:holding_period],
            days_held:             tax[:days_held],
            acquired_at_effective: tax[:acquired_at_effective],
            acquired_at_source:    tax[:source]
          }
          remaining = 0
        end
      end

      write_unlocked(list)

      total_pl = lots_closed.sum { |l| l[:realized_pl] }.round(2)
      tax_split = TaxLot.aggregate_realized(lots_closed)
      {
        symbol:        sym,
        shares_closed: requested.round(6),
        price:         px.round(4),
        sold_at:       sold_iso,
        realized_pl:   total_pl,
        short_term_pl: tax_split[:short_term_pl],
        long_term_pl:  tax_split[:long_term_pl],
        unknown_pl:    tax_split[:unknown_pl],
        lots_closed:   lots_closed
      }
    end
  end

  # Remove ALL lots (open + closed) for a symbol without recording a trade.
  # Use for typo-correction. To realise P&L on a position, call
  # `close_shares_fifo` instead.
  def remove(symbol)
    sym = symbol.to_s.strip.upcase
    MUTEX.synchronize do
      list = read_unlocked.reject { |lot| lot[:symbol] == sym }
      write_unlocked(list)
      list
    end
  end

  # Remove a single lot by id (for "I bought the wrong thing" corrections).
  def remove_lot(lot_id)
    MUTEX.synchronize do
      list = read_unlocked.reject { |lot| lot[:id] == lot_id.to_s }
      write_unlocked(list)
      list
    end
  end

  # --- internals -----------------------------------------------------------

  def read_unlocked
    return [] unless File.exist?(path)
    raw = File.read(path)
    return [] if raw.strip.empty?
    parsed = JSON.parse(raw)
    return [] unless parsed.is_a?(Array)
    parsed.map { |h| migrate(symbolize(h)) }
  rescue JSON::ParserError
    []
  end

  def write_unlocked(list)
    FileUtils.mkdir_p(File.dirname(path))
    tmp = "#{path}.tmp"
    File.write(tmp, JSON.pretty_generate(list))
    File.rename(tmp, path)
  end

  def symbolize(h)
    return {} unless h.is_a?(Hash)
    h.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
  end

  # Backfill new fields on legacy rows so old data keeps working without a
  # one-shot migration script. Adds id/created_at/closed_at if missing.
  def migrate(lot)
    lot[:id]         ||= SecureRandom.hex(6)
    lot[:created_at] ||= Time.now.utc.iso8601
    lot[:closed_at]  ||= nil
    lot
  end

  def normalize_date(raw)
    return nil if raw.nil? || raw.to_s.strip.empty?
    Date.parse(raw.to_s).iso8601
  rescue ArgumentError
    nil
  end
end
