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
    it 'loads the recommendations page with disclaimer' do
      get '/recommendations'
      expect(last_response).to be_ok
      expect(last_response.body).to include('Disclaimer')
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
