require 'rspec'
require_relative '../app/market_data_service'
require_relative '../app/recommendation_service'

RSpec.describe MarketDataService do
  describe '.symbol_type' do
    it 'returns ETF for known ETF symbols' do
      expect(MarketDataService.symbol_type('SPY')).to eq('ETF')
      expect(MarketDataService.symbol_type('QQQ')).to eq('ETF')
      expect(MarketDataService.symbol_type('EWJ')).to eq('ETF')
      expect(MarketDataService.symbol_type('VGK')).to eq('ETF')
    end

    it 'returns Equity for unknown symbols' do
      expect(MarketDataService.symbol_type('AAPL')).to eq('Equity')
      expect(MarketDataService.symbol_type('UNKNOWN')).to eq('Equity')
    end

    it 'uses cached finnhub_type when available' do
      MarketDataService.send(:store_cache, 'profile:TSLA', { name: 'Tesla', finnhub_type: 'EQS' })
      expect(MarketDataService.symbol_type('TSLA')).to eq('Equity')
      MarketDataService.send(:instance_variable_get, :@cache).delete('profile:TSLA')
    end
  end

  describe '.region' do
    it 'returns quotes for US region' do
      result = MarketDataService.region(:us)
      expect(result[:quotes]).to be_an(Array)
      expect(result[:quotes].map { |q| q[:symbol] }).to include('SPY')
    end

    it 'returns quotes for Japan region' do
      result = MarketDataService.region(:japan)
      expect(result[:quotes].map { |q| q[:symbol] }).to include('EWJ')
    end

    it 'returns quotes for Europe region' do
      result = MarketDataService.region(:europe)
      expect(result[:quotes].map { |q| q[:symbol] }).to include('VGK')
    end

    it 'marks data as stale when cache is empty' do
      saved_av  = ENV.delete('ALPHA_VANTAGE_API_KEY')
      saved_fh  = ENV.delete('FINNHUB_API_KEY')
      MarketDataService.bust_cache!
      allow(Net::HTTP).to receive(:start).and_raise(StandardError, 'stubbed')
      allow(Net::HTTP).to receive(:get_response).and_raise(StandardError, 'stubbed')
      result = MarketDataService.region(:us)
      expect(result[:stale]).to be true
    ensure
      ENV['ALPHA_VANTAGE_API_KEY'] = saved_av if saved_av
      ENV['FINNHUB_API_KEY']       = saved_fh if saved_fh
    end
  end

  describe '.bust_cache!' do
    it 'resets the cache' do
      MarketDataService.bust_cache!
      expect(MarketDataService.cache_fresh?).to be_falsy
    end
  end

  describe '.quote (missing API key)' do
    it 'emits a warning to stderr when API key is absent' do
      MarketDataService.clear_all_caches!
      saved_key = ENV.delete('ALPHA_VANTAGE_API_KEY')
      saved_tiingo = ENV.delete('TIINGO_API_KEY')
      saved_finnhub = ENV.delete('FINNHUB_API_KEY')
      saved_rack = ENV.delete('RACK_ENV')
      begin
        expect { MarketDataService.quote('SPY') }.to output(/ALPHA_VANTAGE_API_KEY is not set/).to_stderr
      ensure
        ENV['ALPHA_VANTAGE_API_KEY'] = saved_key if saved_key
        ENV['TIINGO_API_KEY'] = saved_tiingo if saved_tiingo
        ENV['FINNHUB_API_KEY'] = saved_finnhub if saved_finnhub
        ENV['RACK_ENV'] = saved_rack if saved_rack
      end
    end
  end

  describe '.fetch_from_finnhub (private)' do
    it 'returns nil and skips the HTTP call when FINNHUB_API_KEY is absent' do
      saved = ENV.delete('FINNHUB_API_KEY')
      begin
        result = MarketDataService.send(:fetch_from_finnhub, 'SPY')
        expect(result).to be_nil
      ensure
        ENV['FINNHUB_API_KEY'] = saved if saved
      end
    end
  end

  describe '.change_pct_from_tiingo_bars (private)' do
    it 'returns 0 for empty input' do
      expect(MarketDataService.send(:change_pct_from_tiingo_bars, [])).to eq(0)
      expect(MarketDataService.send(:change_pct_from_tiingo_bars, nil)).to eq(0)
    end

    # Regression: the old fetch_from_tiingo_quote requested only the latest
    # EOD bar from Tiingo, so this single-element case fell back to
    # `prev_close = close` and silently emitted 0% — that's why every
    # Tiingo-sourced quote on /dashboard's watchlist showed 0.0%.
    it 'returns 0 when only a single bar is present (regression for watchlist 0% bug)' do
      bars = [{ 'close' => 100.0 }]
      expect(MarketDataService.send(:change_pct_from_tiingo_bars, bars)).to eq(0)
    end

    it 'computes the day-over-day percent from the last two bars' do
      bars = [{ 'close' => 27.06 }, { 'close' => 27.19 }]
      pct  = MarketDataService.send(:change_pct_from_tiingo_bars, bars)
      expect(pct).to be_within(1e-3).of(0.4804) # ≈ +0.48%
    end

    it 'falls back to adjClose when close is missing' do
      bars = [{ 'adjClose' => 100.0 }, { 'adjClose' => 105.0 }]
      pct  = MarketDataService.send(:change_pct_from_tiingo_bars, bars)
      expect(pct).to be_within(1e-3).of(5.0)
    end

    it 'returns 0 when prev close is zero (avoid divide-by-zero)' do
      bars = [{ 'close' => 0.0 }, { 'close' => 5.0 }]
      expect(MarketDataService.send(:change_pct_from_tiingo_bars, bars)).to eq(0)
    end
  end

  describe '.fetch_from_tiingo_quote (private)' do
    it 'requests the last 7 days of bars so prev_close can be computed' do
      ENV['TIINGO_API_KEY'] = 'test_key'
      MarketDataService.instance_variable_set(:@tiingo_quote_rate_limited_until, nil)

      fake_body = [
        { 'close' => 26.99, 'high' => 27.10, 'low' => 26.85, 'open' => 27.00, 'volume' => 100_000 },
        { 'close' => 27.06, 'high' => 27.20, 'low' => 26.90, 'open' => 27.05, 'volume' => 110_000 },
        { 'close' => 27.19, 'high' => 27.48, 'low' => 26.99, 'open' => 27.29, 'volume' => 120_000 }
      ].to_json
      fake_res = instance_double(Net::HTTPSuccess, body: fake_body)
      allow(fake_res).to receive(:is_a?).and_return(false)
      allow(fake_res).to receive(:is_a?).with(Net::HTTPTooManyRequests).and_return(false)
      allow(fake_res).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)

      captured_url = nil
      allow(Net::HTTP).to receive(:start) do |host, port, **opts, &blk|
        # Capture URL by inspecting the Net::HTTP::Get instance the block builds
        fake_res
      end
      # Net::HTTP::Get::new actually receives the URI — intercept that instead.
      allow(Net::HTTP::Get).to receive(:new).and_wrap_original do |original, uri|
        captured_url = uri
        original.call(uri)
      end

      result = MarketDataService.send(:fetch_from_tiingo_quote, 'CMCSA')
      expect(captured_url.to_s).to include('startDate=')
      expect(result['10. change percent']).to match(/0\.4\d+%/)
      expect(result['05. price']).to eq('27.19')
    ensure
      ENV.delete('TIINGO_API_KEY')
    end
  end

  describe '.fetch_from_yahoo (private)' do
    it 'returns a normalized hash with expected keys when Yahoo responds successfully' do
      fake_meta = {
        'regularMarketPrice'         => 520.5,
        'regularMarketChangePercent' => 1.234,
        'regularMarketVolume'        => 82_000_000
      }
      fake_body = { 'chart' => { 'result' => [{ 'meta' => fake_meta }] } }.to_json

      fake_res = instance_double(Net::HTTPSuccess, body: fake_body)
      allow(Net::HTTP).to receive(:start).and_return(fake_res)

      result = MarketDataService.send(:fetch_from_yahoo, 'SPY')
      expect(result['05. price']).to eq('520.5')
      expect(result['10. change percent']).to eq('1.234%')
      expect(result['06. volume']).to eq('82000000')
    end
  end
end

RSpec.describe RecommendationService do
  describe '.signals' do
    it 'returns a signal for each tracked symbol' do
      signals = RecommendationService.signals
      expect(signals).to be_an(Array)
      expect(signals.length).to eq(MarketDataService::REGIONS.values.flatten.length)
      signals.each do |s|
        expect(%w[BUY SELL HOLD]).to include(s[:signal])
      end
    end

    it 'includes signal_type in every signal entry' do
      signals = RecommendationService.signals
      signals.each do |s|
        expect(s[:signal_type]).to be_a(String)
        expect(['Analyst Consensus', 'Momentum Signal']).to include(s[:signal_type])
      end
    end
  end

  describe '.signal_for' do
    it 'returns a valid signal string for a known symbol' do
      signal = RecommendationService.signal_for('SPY')
      expect(%w[BUY SELL HOLD]).to include(signal)
    end
  end

  describe '.signal_detail' do
    it 'returns a hash with :signal, :signal_type, :analyst, :score keys' do
      detail = RecommendationService.signal_detail('SPY')
      expect(detail).to have_key(:signal)
      expect(detail).to have_key(:signal_type)
      expect(detail).to have_key(:analyst)
      expect(detail).to have_key(:score)
      expect(%w[BUY SELL HOLD]).to include(detail[:signal])
    end

    it 'falls back to Momentum Signal when analyst data is nil' do
      allow(MarketDataService).to receive(:analyst_recommendations).and_return(nil)
      detail = RecommendationService.signal_detail('SPY')
      expect(detail[:signal_type]).to eq('Momentum Signal')
      expect(detail[:score]).to be_nil
    end
  end

  describe '.analyst_signal (via signal_detail)' do
    it 'returns BUY when weighted score > 0.5' do
      allow(MarketDataService).to receive(:analyst_recommendations).and_return(
        { strong_buy: 10, buy: 8, hold: 2, sell: 1, strong_sell: 1 }
      )
      detail = RecommendationService.signal_detail('AAPL')
      expect(detail[:signal]).to eq('BUY')
      expect(detail[:signal_type]).to eq('Analyst Consensus')
      expect(detail[:score]).to be > 0.5
    end

    it 'returns SELL when weighted score < -0.5' do
      allow(MarketDataService).to receive(:analyst_recommendations).and_return(
        { strong_buy: 1, buy: 1, hold: 2, sell: 8, strong_sell: 10 }
      )
      detail = RecommendationService.signal_detail('AAPL')
      expect(detail[:signal]).to eq('SELL')
      expect(detail[:score]).to be < -0.5
    end

    it 'returns HOLD when weighted score is between -0.5 and 0.5' do
      allow(MarketDataService).to receive(:analyst_recommendations).and_return(
        { strong_buy: 3, buy: 3, hold: 10, sell: 3, strong_sell: 3 }
      )
      detail = RecommendationService.signal_detail('AAPL')
      expect(detail[:signal]).to eq('HOLD')
      expect(detail[:score]).to be_between(-0.5, 0.5)
    end

    it 'computes score correctly for a pure strong-buy analyst pool' do
      allow(MarketDataService).to receive(:analyst_recommendations).and_return(
        { strong_buy: 10, buy: 0, hold: 0, sell: 0, strong_sell: 0 }
      )
      detail = RecommendationService.signal_detail('AAPL')
      expect(detail[:score]).to eq(2.0)
    end
  end
end

RSpec.describe MarketDataService do
  describe '.analyst_recommendations' do
    it 'returns nil when FINNHUB_API_KEY is absent and no cached data exists' do
      saved = ENV.delete('FINNHUB_API_KEY')
      MarketDataService.clear_all_caches!
      begin
        result = MarketDataService.analyst_recommendations('AAPL')
        expect(result).to be_nil
      ensure
        ENV['FINNHUB_API_KEY'] = saved if saved
      end
    end
  end

  describe '.company_profile' do
    it 'returns a hash with expected keys for ETF SPY (uses hardcoded data)' do
      profile = MarketDataService.company_profile('SPY')
      expect(profile).to be_a(Hash)
      expect(profile[:name]).to include('S&P 500')
      expect(profile[:exchange]).to eq('NYSE Arca')
    end
  end

  describe '.cache_summary' do
    before { MarketDataService.clear_all_caches! }

    it 'returns an empty array when no entries exist' do
      expect(MarketDataService.cache_summary).to eq([])
    end

    it 'derives type :quote for plain symbol keys' do
      MarketDataService.send(:store_cache, 'AAPL', { price: '100' })
      entry = MarketDataService.cache_summary.find { |e| e[:key] == 'AAPL' }
      expect(entry[:type]).to eq('quote')
      expect(entry[:symbol]).to eq('AAPL')
      expect(entry[:period]).to be_nil
    end

    it 'derives type :analyst for analyst: prefixed keys' do
      MarketDataService.send(:store_cache, 'analyst:AAPL', { buy: 5 })
      entry = MarketDataService.cache_summary.find { |e| e[:key] == 'analyst:AAPL' }
      expect(entry[:type]).to eq('analyst')
      expect(entry[:symbol]).to eq('AAPL')
    end

    it 'derives type :profile for profile: prefixed keys' do
      MarketDataService.send(:store_cache, 'profile:MSFT', { name: 'Microsoft' })
      entry = MarketDataService.cache_summary.find { |e| e[:key] == 'profile:MSFT' }
      expect(entry[:type]).to eq('profile')
      expect(entry[:symbol]).to eq('MSFT')
    end

    it 'derives type :candle and captures period for candle: prefixed keys' do
      MarketDataService.send(:store_cache, 'candle:SPY:1y', [{ t: 1, o: 100 }])
      entry = MarketDataService.cache_summary.find { |e| e[:key] == 'candle:SPY:1y' }
      expect(entry[:type]).to eq('candle')
      expect(entry[:symbol]).to eq('SPY')
      expect(entry[:period]).to eq('1y')
    end

    it 'sets is_stale false for live cache entries' do
      MarketDataService.send(:store_cache, 'AAPL', { price: '100' })
      entry = MarketDataService.cache_summary.find { |e| e[:key] == 'AAPL' }
      expect(entry[:is_stale]).to be false
    end

    it 'sets is_stale true when entry is only in persistent cache' do
      MarketDataService.send(:store_cache, 'AAPL', { price: '100' })
      MarketDataService.bust_cache!
      entry = MarketDataService.cache_summary.find { |e| e[:key] == 'AAPL' }
      expect(entry[:is_stale]).to be true
    end

    it 'returns cached_at timestamp for stored entries' do
      MarketDataService.send(:store_cache, 'AAPL', { price: '100' })
      entry = MarketDataService.cache_summary.find { |e| e[:key] == 'AAPL' }
      expect(entry[:cached_at]).to be_a(Time)
    end

    it 'marks entry stale when cached_at is older than CACHE_TTL' do
      ENV['MARKET_OPEN'] = '1' # pin to market-hours TTL so CACHE_TTL is the cutoff
      key = 'candle:SPY:1y'
      MarketDataService.send(:store_cache, key, [{ date: '2026-01-01', close: 100.0 }])
      old_ts = Time.now - MarketDataService::CACHE_TTL - 60
      MarketDataService.instance_variable_get(:@cache_timestamps)[key] = old_ts

      entry = MarketDataService.cache_summary.find { |e| e[:key] == key }
      expect(entry[:is_stale]).to be true
    ensure
      ENV.delete('MARKET_OPEN')
    end
  end

  describe '.historical with expired cache' do
    it 'does not serve a live historical entry older than CACHE_TTL' do
      ENV['MARKET_OPEN'] = '1' # pin to market-hours TTL so CACHE_TTL is the cutoff
      key = 'candle:SPY:1y'
      points = [{ date: '2026-01-01', close: 100.0 }]
      MarketDataService.send(:store_cache, key, points)
      MarketDataService.instance_variable_get(:@cache_timestamps)[key] = Time.now - MarketDataService::CACHE_TTL - 60

      allow(MarketDataService).to receive(:prefetch_all_historical).and_return({})
      allow(MarketDataService).to receive(:fetch_historical_from_yahoo).and_return(nil)
      allow(MarketDataService).to receive(:fetch_historical_from_finnhub).and_return(nil)
      allow(MarketDataService).to receive(:fetch_historical_from_tiingo).and_return(nil)
      allow(MarketDataService).to receive(:fetch_historical_from_alpha_vantage).and_return(nil)

      result = MarketDataService.historical('SPY', '1y')
      expect(result).to eq(points)
      expect(MarketDataService.instance_variable_get(:@cache)[key]).to be_nil
    ensure
      ENV.delete('MARKET_OPEN')
    end
  end
end