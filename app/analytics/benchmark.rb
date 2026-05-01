require 'date'

module Analytics
  # Benchmark — answer "how is my portfolio doing vs the S&P 500?" using
  # already-cached data only (no provider calls on render).
  #
  # Method (lot-weighted return-since-acquired):
  #   For each open lot we compute its return as
  #     (current_price - cost_basis) / cost_basis
  #   For the same lot we compute the benchmark return over the same window
  #     (benchmark_now - benchmark_at_acquired) / benchmark_at_acquired
  #   Weight each lot by its cost-value, sum, normalise.
  #
  # Why this method (and not strict TWR / IRR):
  #   - TWR needs every cash-flow / position change with timestamps —
  #     we don't track that granularly.
  #   - IRR / MWR has the same problem and is sensitive to deposit timing
  #     (Fidelity-imported lots have synthetic acquired_at).
  #   - Lot-weighted return-since-acquired gives the *honest* answer:
  #     "for every dollar I put into this position on this date, how much
  #     would the same dollar in SPY have made over the same window?"
  #   - This is exactly the question a personal investor cares about.
  #
  # All bar reads are cache-only via the historical-cache files
  # (`MarketDataService.historical` is itself cache-friendly under the
  # market-aware TTL). The benchmark fetch happens once per render.
  module Benchmark
    DEFAULT_BENCHMARK = 'SPY'.freeze

    module_function

    # Compute the lot-weighted comparison.
    # Inputs:
    #   positions: aggregated positions from PortfolioStore.positions, each
    #              with :symbol, :lots, :current_price, :cost_basis (basis
    #              and price are filled in by valuate_position; pass the
    #              valuated rows).
    #   benchmark: ticker string (default 'SPY')
    #   bars_for:  proc that returns historical bars for a symbol; in
    #              production this is `->(s){ MarketDataService.historical(s, '5y') }`.
    #              Injected so tests can stub.
    #
    # Returns:
    #   { benchmark:, portfolio_return:, benchmark_return:, alpha:,
    #     cost_basis:, lots_priced:, lots_skipped:, as_of: ISO date }
    # All return values are decimals (0.123 = 12.3%); render via format_percent.
    def compare(positions, benchmark: DEFAULT_BENCHMARK, bars_for:)
      bench_bars = bars_for.call(benchmark) || []
      return empty_result(benchmark) if bench_bars.empty?

      bench_index = bars_index(bench_bars)
      latest_bench = bench_bars.last
      latest_bench_close = (latest_bench[:close] || latest_bench['close']).to_f
      return empty_result(benchmark) if latest_bench_close.zero?

      cost_total       = 0.0
      port_value_total = 0.0
      bench_value_total = 0.0
      lots_priced      = 0
      lots_skipped     = 0

      positions.each do |pos|
        next if pos[:current_price].nil? || pos[:current_price].to_f.zero?
        Array(pos[:lots]).each do |lot|
          shares  = lot[:shares].to_f
          basis   = lot[:cost_basis].to_f
          next if shares <= 0 || basis <= 0

          cost = shares * basis
          port_now = shares * pos[:current_price].to_f

          # Benchmark return for the lot's window: from acquired_at (or the
          # earliest available bar after it) to today.
          acq_iso = lot[:acquired_at] || lot[:created_at]
          bench_close_at_acq = closest_bar_close(bench_index, acq_iso)
          if bench_close_at_acq.nil? || bench_close_at_acq.zero?
            lots_skipped += 1
            next
          end
          bench_now_dollars = cost * (latest_bench_close / bench_close_at_acq)

          cost_total        += cost
          port_value_total  += port_now
          bench_value_total += bench_now_dollars
          lots_priced       += 1
        end
      end

      if cost_total.zero?
        return empty_result(benchmark).merge(lots_skipped: lots_skipped)
      end

      portfolio_return = (port_value_total - cost_total) / cost_total
      benchmark_return = (bench_value_total - cost_total) / cost_total

      {
        benchmark:        benchmark,
        portfolio_return: portfolio_return.round(6),
        benchmark_return: benchmark_return.round(6),
        alpha:            (portfolio_return - benchmark_return).round(6),
        cost_basis:       cost_total.round(2),
        portfolio_value:  port_value_total.round(2),
        benchmark_value:  bench_value_total.round(2),
        lots_priced:      lots_priced,
        lots_skipped:     lots_skipped,
        as_of:            (latest_bench[:date] || latest_bench['date']).to_s
      }
    end

    # --- internals ---------------------------------------------------------

    def bars_index(bars)
      bars.each_with_object({}) do |b, h|
        date = (b[:date] || b['date']).to_s
        h[date] = (b[:close] || b['close']).to_f
      end
    end

    # Look up the bar's close on `iso_date`, falling forward to the next
    # available trading day if `iso_date` was a weekend / market holiday.
    def closest_bar_close(index, iso_date)
      return nil if iso_date.nil? || iso_date.to_s.empty?
      target = iso_date.to_s[0, 10]
      return index[target] if index.key?(target)

      # Linear scan forward up to 10 calendar days.
      d = begin
        Date.parse(target)
      rescue StandardError
        return nil
      end
      10.times do
        d += 1
        key = d.iso8601
        return index[key] if index.key?(key)
      end
      # Otherwise fall back to the earliest bar — better an old comparison
      # than no comparison.
      index.values.first
    end

    def empty_result(benchmark)
      {
        benchmark:        benchmark,
        portfolio_return: nil,
        benchmark_return: nil,
        alpha:            nil,
        cost_basis:       0,
        portfolio_value:  0,
        benchmark_value:  0,
        lots_priced:      0,
        lots_skipped:     0,
        as_of:            nil
      }
    end
  end
end
