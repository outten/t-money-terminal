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
  end

  describe '.signal_for' do
    it 'returns a valid signal string for a known symbol' do
      signal = RecommendationService.signal_for('SPY')
      expect(%w[BUY SELL HOLD]).to include(signal)
    end
  end
end