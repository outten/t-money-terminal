require 'json'
require 'fileutils'
require 'date'
require 'time'
require 'securerandom'

# TradesStore — append-only trade history at `data/trades.json`.
#
# A trade is a single user action (BUY or SELL):
#
#   { id:, date: ISO date, recorded_at: ISO timestamp, symbol:, side: 'buy'|'sell',
#     shares:, price:, realized_pl: (nil for buys, sum across closed lots for sells),
#     lots_closed: [{lot_id:, shares:, cost_basis:, realized_pl:}, ...],
#     notes: }
#
# Buys are recorded for audit (the resulting lot lives in PortfolioStore).
# Sells are recorded with their FIFO breakdown (which lots were closed and at
# what cost basis) so the trade page can show realized P&L per close.
#
# Storage is a JSON array. We keep it simple — for a single-user terminal,
# append-only on a JSON array is fine; if it ever grows past ~10k trades a
# move to SQLite is in order.
module TradesStore
  DEFAULT_PATH = File.expand_path('../../data/trades.json', __FILE__)
  MUTEX        = Mutex.new
  VALID_SIDES  = %w[buy sell].freeze

  module_function

  def path
    ENV['TRADES_PATH'] || DEFAULT_PATH
  end

  # All trades, oldest-first.
  def read
    list = read_unlocked
    list.sort_by { |t| [t[:date].to_s, t[:recorded_at].to_s] }
  end

  # Trades within `[from, to]` (Date or ISO string), oldest-first.
  def between(from:, to:)
    f = parse_date(from)
    t = parse_date(to)
    read.select do |trade|
      d = parse_date(trade[:date])
      next false unless d
      (f.nil? || d >= f) && (t.nil? || d <= t)
    end
  end

  # Trades for a symbol, oldest-first.
  def for_symbol(symbol)
    sym = symbol.to_s.upcase
    read.select { |t| t[:symbol] == sym }
  end

  # Sum of realized P&L across all sells in `[from, to]`. Useful for the
  # year-to-date realized P&L card on the dashboard.
  def realized_pl_total(from: nil, to: nil)
    list = (from || to) ? between(from: from, to: to) : read
    list.select { |t| t[:side] == 'sell' }.sum { |t| t[:realized_pl].to_f }.round(2)
  end

  def realized_pl_ytd
    today = Date.today
    realized_pl_total(from: Date.new(today.year, 1, 1), to: today)
  end

  # Append a BUY record (after PortfolioStore.add_lot).
  def record_buy(symbol:, shares:, price:, date: nil, notes: nil, lot_id: nil)
    append({
      id:          SecureRandom.hex(6),
      date:        normalize_date(date) || Date.today.iso8601,
      recorded_at: Time.now.utc.iso8601,
      symbol:      symbol.to_s.upcase,
      side:        'buy',
      shares:      Float(shares).round(6),
      price:       Float(price).round(4),
      realized_pl: nil,
      lots_closed: nil,
      lot_id:      lot_id,
      notes:       (notes.to_s.strip.empty? ? nil : notes.to_s.strip)
    })
  end

  # Append a SELL record (after PortfolioStore.close_shares_fifo). `breakdown`
  # is the hash returned by close_shares_fifo.
  def record_sell(breakdown, notes: nil)
    append({
      id:          SecureRandom.hex(6),
      date:        breakdown[:sold_at] || Date.today.iso8601,
      recorded_at: Time.now.utc.iso8601,
      symbol:      breakdown[:symbol],
      side:        'sell',
      shares:      breakdown[:shares_closed],
      price:       breakdown[:price],
      realized_pl: breakdown[:realized_pl],
      lots_closed: breakdown[:lots_closed],
      lot_id:      nil,
      notes:       (notes.to_s.strip.empty? ? nil : notes.to_s.strip)
    })
  end

  # --- internals -----------------------------------------------------------

  def append(trade)
    MUTEX.synchronize do
      list = read_unlocked
      list << trade
      write_unlocked(list)
    end
    trade
  end

  def read_unlocked
    return [] unless File.exist?(path)
    raw = File.read(path)
    return [] if raw.strip.empty?
    parsed = JSON.parse(raw)
    return [] unless parsed.is_a?(Array)
    parsed.map { |h| symbolize(h) }
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

  def normalize_date(raw)
    return nil if raw.nil? || raw.to_s.strip.empty?
    Date.parse(raw.to_s).iso8601
  rescue ArgumentError
    nil
  end

  def parse_date(raw)
    return raw if raw.is_a?(Date)
    Date.parse(raw.to_s)
  rescue StandardError
    nil
  end
end
