require 'json'
require 'fileutils'
require 'date'

# PortfolioStore — file-backed single-user portfolio of holdings persisted at
# `data/portfolio.json`.
#
# Each holding records the entry data needed to compute unrealized P&L:
#
#   { symbol:, shares:, cost_basis:, acquired_at: (ISO date|nil), notes: }
#
# `cost_basis` is the average price per share at entry (a single scalar — we
# don't track tax lots; for that you'd want SQLite). Live market value is
# computed on render by joining against `MarketDataService.quote(symbol)`.
#
# Only one holding per symbol — upsert replaces an existing entry. Mutations
# acquire an in-process mutex so concurrent Sinatra requests can't interleave
# writes; persistence uses an atomic rename-over-tmp like WatchlistStore.
module PortfolioStore
  DEFAULT_PATH = File.expand_path('../../data/portfolio.json', __FILE__)
  MUTEX        = Mutex.new

  module_function

  def path
    ENV['PORTFOLIO_PATH'] || DEFAULT_PATH
  end

  # Returns the portfolio as an array of holding hashes (symbol keys).
  def read
    return [] unless File.exist?(path)
    raw = File.read(path)
    return [] if raw.strip.empty?
    parsed = JSON.parse(raw)
    return [] unless parsed.is_a?(Array)
    parsed.map { |h| symbolize(h) }
  rescue JSON::ParserError
    []
  end

  def find(symbol)
    sym = symbol.to_s.upcase
    read.find { |h| h[:symbol] == sym }
  end

  def symbols
    read.map { |h| h[:symbol] }
  end

  # Insert or replace a holding. Returns the saved hash.
  # Raises ArgumentError on invalid input.
  def upsert(symbol:, shares:, cost_basis:, acquired_at: nil, notes: nil)
    sym = symbol.to_s.strip.upcase
    raise ArgumentError, 'symbol required' if sym.empty?

    sh = Float(shares) rescue nil
    raise ArgumentError, 'shares must be a positive number' if sh.nil? || sh <= 0

    cb = Float(cost_basis) rescue nil
    raise ArgumentError, 'cost_basis must be a positive number' if cb.nil? || cb <= 0

    acq = normalize_date(acquired_at)

    holding = {
      symbol:      sym,
      shares:      sh.round(6),
      cost_basis:  cb.round(4),
      acquired_at: acq,
      notes:       notes.to_s.strip.empty? ? nil : notes.to_s.strip
    }

    MUTEX.synchronize do
      list = read_unlocked.reject { |h| h[:symbol] == sym }
      list << holding
      list.sort_by! { |h| h[:symbol] }
      write_unlocked(list)
    end
    holding
  end

  def remove(symbol)
    sym = symbol.to_s.strip.upcase
    MUTEX.synchronize do
      list = read_unlocked.reject { |h| h[:symbol] == sym }
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
end
