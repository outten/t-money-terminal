require 'rack/test'
require 'rspec'
require_relative '../app/main'

ENV['RACK_ENV'] = 'test'

RSpec.describe TMoneyTerminal do
  include Rack::Test::Methods

  def app
    TMoneyTerminal
  end

  describe 'GET /' do
    it 'redirects to /dashboard' do
      get '/'
      expect(last_response.status).to eq(302)
    end
  end

  describe 'GET /dashboard' do
    it 'loads the dashboard page' do
      get '/dashboard'
      expect(last_response).to be_ok
      expect(last_response.body).to include('Dashboard')
    end
  end

  describe 'GET /us' do
    it 'loads the US markets page' do
      get '/us'
      expect(last_response).to be_ok
      expect(last_response.body).to include('US Markets')
    end
  end

  describe 'GET /japan' do
    it 'loads the Japan markets page' do
      get '/japan'
      expect(last_response).to be_ok
      expect(last_response.body).to include('Japan')
    end
  end

  describe 'GET /europe' do
    it 'loads the Europe markets page' do
      get '/europe'
      expect(last_response).to be_ok
      expect(last_response.body).to include('Europe')
    end
  end

  describe 'GET /recommendations' do
    it 'redirects to /dashboard with 301' do
      get '/recommendations'
      expect(last_response.status).to eq(301)
      expect(last_response.location).to include('/dashboard')
    end
  end

  describe 'GET /analysis/:symbol' do
    it 'loads the analysis page for a valid symbol' do
      get '/analysis/SPY'
      expect(last_response).to be_ok
      expect(last_response.body).to include('SPY')
    end

    it 'refreshes using live-cache bust and redirects' do
      expect(MarketDataService).to receive(:refresh_symbol_live_cache!).with('SPY')
      get '/analysis/SPY?refresh=1'
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include('/analysis/SPY')
    end

    it 'returns 404 for an unknown symbol' do
      get '/analysis/INVALID'
      expect(last_response.status).to eq(404)
    end
  end

  describe 'GET /api/candle/:symbol/:period' do
    it 'returns JSON for a valid symbol and period' do
      get '/api/candle/SPY/1y'
      expect(last_response).to be_ok
      expect(last_response.content_type).to include('application/json')
    end

    it 'returns 404 for invalid symbol' do
      get '/api/candle/INVALID/1y'
      expect(last_response.status).to eq(404)
    end
  end

  describe 'GET /region/:name' do
    it 'loads the US region page' do
      get '/region/us'
      expect(last_response).to be_ok
      expect(last_response.body).to include('US')
    end

    it 'loads the Japan region page' do
      get '/region/japan'
      expect(last_response).to be_ok
      expect(last_response.body).to include('Japan')
    end

    it 'loads the Europe region page' do
      get '/region/europe'
      expect(last_response).to be_ok
      expect(last_response.body).to include('Europe')
    end

    it 'returns 404 for unknown region name' do
      get '/region/unknown'
      expect(last_response.status).to eq(404)
    end
  end

  describe 'GET /api/market/:region' do
    it 'returns JSON for US region' do
      get '/api/market/us'
      expect(last_response).to be_ok
      expect(last_response.content_type).to include('application/json')
    end
  end

  describe 'GET /admin/cache' do
    it 'returns 200 when cache has entries' do
      MarketDataService.send(:store_cache, 'AAPL', { price: '100' })
      get '/admin/cache'
      expect(last_response).to be_ok
      expect(last_response.body).to include('AAPL')
    end

    it 'returns 200 with empty-state message when cache is empty' do
      MarketDataService.clear_all_caches!
      get '/admin/cache'
      expect(last_response).to be_ok
      expect(last_response.body).to include('No cache entries found')
    end
  end
  
  describe 'POST /refresh/dashboard' do
    it 'busts cache for all symbols and redirects to dashboard' do
      all_symbols = MarketDataService::REGIONS.values.flatten.uniq
      all_symbols.each do |symbol|
        expect(MarketDataService).to receive(:bust_cache_for_symbol!).with(symbol)
      end
      
      post '/refresh/dashboard'
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include('/dashboard')
    end
  end
  
  describe 'POST /refresh/region/:name' do
    it 'busts cache for US region symbols and redirects' do
      MarketDataService::REGIONS[:us].each do |symbol|
        expect(MarketDataService).to receive(:bust_cache_for_symbol!).with(symbol)
      end
      
      post '/refresh/region/us'
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include('/region/us')
    end
    
    it 'returns 404 for unknown region' do
      post '/refresh/region/unknown'
      expect(last_response.status).to eq(404)
    end
  end
  
  describe 'POST /refresh/analysis/:symbol' do
    it 'busts cache for single symbol and redirects to analysis page' do
      expect(MarketDataService).to receive(:bust_cache_for_symbol!).with('SPY')
      
      post '/refresh/analysis/SPY'
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include('/analysis/SPY')
    end
    
    it 'returns 404 for unknown symbol' do
      post '/refresh/analysis/INVALID'
      expect(last_response.status).to eq(404)
    end
  end
end
