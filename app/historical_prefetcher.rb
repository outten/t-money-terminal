require_relative 'market_data_service'

# HistoricalPrefetcher — fire-and-forget background fetch of historical bars
# for an array of symbols, used right after a broker import so the candle
# cache is warm before the user navigates to any /analysis page.
#
# The expensive path (Polygon free tier @ 5/min, 13s throttle gate) takes
# a few minutes for ~20 symbols, so this MUST be async — running it
# inline would freeze the import POST. The thread runs sequentially so
# provider rate-limit throttles serialise naturally; multiple concurrent
# threads would just queue up at `Providers::Throttle` anyway.
#
# Design constraints:
# - Errors per-symbol are logged + swallowed; one bad ticker doesn't
#   abort the rest of the queue.
# - HealthRegistry already records every provider call, so progress is
#   observable via /admin/health.
# - In test env this is a no-op (set HISTORICAL_PREFETCH=1 to opt in).
#   The synchronous `prefetch_each` is exposed for tests that want to
#   exercise the worker logic deterministically.
module HistoricalPrefetcher
  module_function

  # Spawn a background thread to prefetch bars for each symbol. Returns the
  # Thread (mostly so tests can join on it), or nil when disabled.
  def prefetch_async(symbols, period: '1y')
    return nil if disabled?
    list = Array(symbols).compact.uniq
    return nil if list.empty?

    Thread.new do
      Thread.current.name = "historical-prefetch-#{list.length}" if Thread.current.respond_to?(:name=)
      Thread.current.report_on_exception = false                  if Thread.current.respond_to?(:report_on_exception=)
      prefetch_each(list, period: period)
    rescue StandardError => e
      warn "[prefetch] thread aborted: #{e.class}: #{e.message}" unless test_env?
    end
  end

  # Synchronous variant. Returns an array of per-symbol results:
  #   [{ symbol:, ok:, bars_count:, error: }, ...]
  # Useful for tests + future callers (CLI prefetch script, etc.).
  def prefetch_each(symbols, period: '1y')
    Array(symbols).map do |sym|
      bars = MarketDataService.historical(sym, period)
      { symbol: sym, ok: !bars.nil? && !bars.empty?, bars_count: bars.is_a?(Array) ? bars.length : 0, error: nil }
    rescue StandardError => e
      warn "[prefetch] #{sym}: #{e.class}: #{e.message}" unless test_env?
      { symbol: sym, ok: false, bars_count: 0, error: "#{e.class}: #{e.message}" }
    end
  end

  # Disabled in test env unless HISTORICAL_PREFETCH=1 is set, AND can be
  # explicitly off-switched at any time via HISTORICAL_PREFETCH=0.
  def disabled?
    return true  if ENV['HISTORICAL_PREFETCH'] == '0'
    return false if ENV['HISTORICAL_PREFETCH'] == '1'
    test_env?
  end

  def test_env?
    ENV['RACK_ENV'] == 'test'
  end
end
