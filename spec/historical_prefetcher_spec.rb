require 'rspec'
require 'tmpdir'

ENV['RACK_ENV'] = 'test'

require_relative '../app/historical_prefetcher'
require_relative '../app/market_data_service'

RSpec.describe HistoricalPrefetcher do
  describe '.prefetch_each (synchronous)' do
    it 'calls MarketDataService.historical for each symbol and reports per-symbol results' do
      received = []
      allow(MarketDataService).to receive(:historical) do |sym, period|
        received << [sym, period]
        [{ date: '2026-04-29', close: 100.0 }] # 1-bar stub
      end

      results = HistoricalPrefetcher.prefetch_each(%w[AAPL NVDA VOO])
      expect(received.map(&:first)).to eq(%w[AAPL NVDA VOO])
      expect(received.first.last).to eq('1y')                # default period
      expect(results.length).to eq(3)
      expect(results.first[:ok]).to be true
      expect(results.first[:bars_count]).to eq(1)
    end

    it 'swallows per-symbol errors so one bad ticker does not abort the rest' do
      allow(MarketDataService).to receive(:historical) do |sym, _|
        raise 'boom' if sym == 'BAD'
        [{ date: '2026-04-29', close: 100.0 }]
      end

      results = HistoricalPrefetcher.prefetch_each(%w[AAPL BAD NVDA])
      by_symbol = results.each_with_object({}) { |r, h| h[r[:symbol]] = r }
      expect(by_symbol['AAPL'][:ok]).to be true
      expect(by_symbol['BAD'][:ok]).to be false
      expect(by_symbol['BAD'][:error]).to include('boom')
      expect(by_symbol['NVDA'][:ok]).to be true
    end

    it 'reports ok: false (and 0 bars_count) when historical returns nil/empty' do
      allow(MarketDataService).to receive(:historical).and_return(nil)
      results = HistoricalPrefetcher.prefetch_each(%w[X])
      expect(results.first[:ok]).to be false
      expect(results.first[:bars_count]).to eq(0)
    end

    it 'honours a custom period: kwarg' do
      received_periods = []
      allow(MarketDataService).to receive(:historical) do |_, period|
        received_periods << period
        []
      end
      HistoricalPrefetcher.prefetch_each(%w[AAPL], period: '5y')
      expect(received_periods).to eq(['5y'])
    end
  end

  describe '.prefetch_async (background thread)' do
    it 'is a no-op in test env unless HISTORICAL_PREFETCH=1 is set' do
      expect(MarketDataService).not_to receive(:historical)
      result = HistoricalPrefetcher.prefetch_async(%w[AAPL])
      expect(result).to be_nil
    end

    it 'opt-in returns a Thread that runs prefetch_each over the symbol list' do
      ENV['HISTORICAL_PREFETCH'] = '1'
      seen = []
      allow(MarketDataService).to receive(:historical) do |sym, _|
        seen << sym
        []
      end

      thread = HistoricalPrefetcher.prefetch_async(%w[AAPL NVDA])
      expect(thread).to be_a(Thread)
      thread.join
      expect(seen).to match_array(%w[AAPL NVDA])
    ensure
      ENV.delete('HISTORICAL_PREFETCH')
    end

    it 'returns nil for empty / nil input even when enabled' do
      ENV['HISTORICAL_PREFETCH'] = '1'
      expect(HistoricalPrefetcher.prefetch_async([])).to be_nil
      expect(HistoricalPrefetcher.prefetch_async(nil)).to be_nil
    ensure
      ENV.delete('HISTORICAL_PREFETCH')
    end

    it 'is also a no-op when HISTORICAL_PREFETCH=0 (kill-switch)' do
      ENV['HISTORICAL_PREFETCH'] = '0'
      expect(MarketDataService).not_to receive(:historical)
      expect(HistoricalPrefetcher.prefetch_async(%w[AAPL])).to be_nil
    ensure
      ENV.delete('HISTORICAL_PREFETCH')
    end

    it 'dedupes the symbol list before kicking off' do
      ENV['HISTORICAL_PREFETCH'] = '1'
      seen = []
      allow(MarketDataService).to receive(:historical) do |sym, _|
        seen << sym
        []
      end
      thread = HistoricalPrefetcher.prefetch_async(%w[AAPL AAPL NVDA])
      thread.join
      expect(seen).to eq(%w[AAPL NVDA])
    ensure
      ENV.delete('HISTORICAL_PREFETCH')
    end
  end
end
