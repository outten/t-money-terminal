require 'rspec'
require_relative '../app/market_data_service'
require_relative '../app/recommendation_service'

RSpec.describe MarketDataService do
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
      MarketDataService.bust_cache!
      saved_key = ENV.delete('ALPHA_VANTAGE_API_KEY')
      saved_rack = ENV.delete('RACK_ENV')
      begin
        expect { MarketDataService.quote('SPY') }.to output(/ALPHA_VANTAGE_API_KEY is not set/).to_stderr
      ensure
        ENV['ALPHA_VANTAGE_API_KEY'] = saved_key if saved_key
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
      expect(signals.length).to eq(5)
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
    it 'returns a hash with :signal, :signal_type, :analyst keys' do
      detail = RecommendationService.signal_detail('SPY')
      expect(detail).to have_key(:signal)
      expect(detail).to have_key(:signal_type)
      expect(detail).to have_key(:analyst)
      expect(%w[BUY SELL HOLD]).to include(detail[:signal])
    end

    it 'falls back to Momentum Signal when analyst data is nil' do
      allow(MarketDataService).to receive(:analyst_recommendations).and_return(nil)
      detail = RecommendationService.signal_detail('SPY')
      expect(detail[:signal_type]).to eq('Momentum Signal')
    end
  end

  describe '.analyst_signal (via signal_detail)' do
    it 'returns BUY when strong_buy + buy significantly outweigh bears' do
      allow(MarketDataService).to receive(:analyst_recommendations).and_return(
        { strong_buy: 10, buy: 8, hold: 2, sell: 1, strong_sell: 1 }
      )
      detail = RecommendationService.signal_detail('AAPL')
      expect(detail[:signal]).to eq('BUY')
      expect(detail[:signal_type]).to eq('Analyst Consensus')
    end

    it 'returns SELL when bears significantly outweigh bulls' do
      allow(MarketDataService).to receive(:analyst_recommendations).and_return(
        { strong_buy: 1, buy: 1, hold: 2, sell: 8, strong_sell: 10 }
      )
      detail = RecommendationService.signal_detail('AAPL')
      expect(detail[:signal]).to eq('SELL')
    end

    it 'returns HOLD when bulls and bears are balanced' do
      allow(MarketDataService).to receive(:analyst_recommendations).and_return(
        { strong_buy: 3, buy: 3, hold: 10, sell: 3, strong_sell: 3 }
      )
      detail = RecommendationService.signal_detail('AAPL')
      expect(detail[:signal]).to eq('HOLD')
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
end