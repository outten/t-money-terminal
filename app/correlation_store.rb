require 'digest'
require_relative 'analytics'
require_relative 'providers/cache_store'

# CorrelationStore — computes and caches correlation matrices keyed on
# (sorted symbols, period). The actual computation is pure Ruby in
# `Analytics::Risk.correlation_matrix`; this module just orchestrates:
#
#   1. Fetch historical bars for each requested symbol (cached at the
#      MarketDataService layer — those calls cost nothing on a warm cache).
#   2. Hash (sorted symbols, period) into a stable cache key.
#   3. Read/write the matrix to `data/cache/correlations/<key>.json` via the
#      existing `Providers::CacheStore` infra (1-hour TTL).
#
# In test mode `Providers::CacheStore` is a no-op (so tests can't accidentally
# read stale fixtures), so the matrix is always recomputed there. Callers that
# want to verify caching wire spies onto MarketDataService.historical instead.
module CorrelationStore
  NAMESPACE = 'correlations'.freeze
  TTL       = 3600 # 1h, matches the rest of the cache layer

  module_function

  # Compute (or fetch from cache) the correlation matrix for `symbols` over
  # `period`. Returns `{ symbols:, matrix:, period:, cached_at: (Time|nil) }`.
  # Symbols are returned in the same order they were requested so the UI can
  # label rows/columns deterministically.
  def matrix_for(symbols, period:)
    syms  = symbols.map(&:to_s).map(&:upcase).uniq
    return empty_payload(syms, period) if syms.empty?

    key = build_key(syms, period)

    cached = Providers::CacheStore.read(NAMESPACE, key, ttl: TTL)
    return cached.merge('cached_at' => Providers::CacheStore.cached_at(NAMESPACE, key)&.iso8601) if cached

    series_by_symbol = syms.each_with_object({}) do |sym, acc|
      bars = fetch_history(sym, period)
      acc[sym] = bars if bars && !bars.empty?
    end

    out = Analytics::Risk.correlation_matrix(series_by_symbol)
    payload = {
      'symbols' => out[:symbols],
      'matrix'  => out[:matrix],
      'period'  => period,
      'count'   => out[:symbols].length
    }
    Providers::CacheStore.write(NAMESPACE, key, payload)
    payload
  end

  # --- internals -----------------------------------------------------------

  def fetch_history(symbol, period)
    MarketDataService.historical(symbol, period)
  rescue StandardError
    nil
  end

  def build_key(symbols, period)
    sorted = symbols.sort.join(',')
    digest = Digest::SHA1.hexdigest("#{period}|#{sorted}")[0, 12]
    "#{period}_#{digest}"
  end

  def empty_payload(symbols, period)
    {
      'symbols' => symbols,
      'matrix'  => [],
      'period'  => period,
      'count'   => 0
    }
  end
end
