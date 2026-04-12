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
end
