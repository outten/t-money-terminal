require 'rack/test'
require 'rspec'
require 'tmpdir'
require 'json'

ENV['RACK_ENV'] = 'test'

require_relative '../app/main'

RSpec.describe 'Section 4 — UX features' do
  include Rack::Test::Methods

  def app
    TMoneyTerminal
  end

  # Isolate the file-backed stores per example so tests don't clobber real data.
  around(:each) do |ex|
    Dir.mktmpdir do |dir|
      ENV['WATCHLIST_PATH']   = File.join(dir, 'watchlist.json')
      ENV['ALERTS_PATH']      = File.join(dir, 'alerts.json')
      ENV['ALERTS_LOG_PATH']  = File.join(dir, 'alerts.log')
      ENV['PORTFOLIO_PATH']   = File.join(dir, 'portfolio.json')
      ex.run
      ENV.delete('WATCHLIST_PATH')
      ENV.delete('ALERTS_PATH')
      ENV.delete('ALERTS_LOG_PATH')
      ENV.delete('PORTFOLIO_PATH')
    end
  end

  # ---- §4.1 Search -------------------------------------------------------
  describe 'SymbolIndex' do
    it 'contains every REGIONS symbol' do
      symbols = SymbolIndex.symbols
      MarketDataService::REGIONS.values.flatten.each do |sym|
        expect(symbols).to include(sym)
      end
    end

    it 'ranks an exact-symbol match first' do
      results = SymbolIndex.search('AAPL')
      expect(results.first[:symbol]).to eq('AAPL')
    end

    it 'matches by name' do
      results = SymbolIndex.search('Microsoft')
      expect(results.map { |r| r[:symbol] }).to include('MSFT')
    end

    it 'returns [] for empty input' do
      expect(SymbolIndex.search('')).to eq([])
    end

    it 'knows? reports membership' do
      expect(SymbolIndex.known?('AAPL')).to be true
      expect(SymbolIndex.known?('ZZZZZ')).to be false
    end
  end

  describe 'GET /api/symbols' do
    it 'returns the full universe when q is blank' do
      get '/api/symbols'
      expect(last_response).to be_ok
      body = JSON.parse(last_response.body)
      expect(body['results']).to be_an(Array)
      expect(body['results'].length).to eq(body['total'])
      expect(body['results'].first).to include('symbol', 'name', 'region')
    end

    it 'ranks exact-match first for q=AAPL' do
      get '/api/symbols?q=AAPL'
      body = JSON.parse(last_response.body)
      expect(body['results'].first['symbol']).to eq('AAPL')
    end

    it 'honours limit' do
      get '/api/symbols?q=A&limit=3'
      body = JSON.parse(last_response.body)
      expect(body['results'].length).to be <= 3
    end
  end

  # ---- §4.2 Watchlist ----------------------------------------------------
  describe 'WatchlistStore' do
    it 'starts empty' do
      expect(WatchlistStore.read).to eq([])
    end

    it 'adds and dedupes' do
      WatchlistStore.add('aapl')
      WatchlistStore.add('AAPL')
      expect(WatchlistStore.read).to eq(['AAPL'])
    end

    it 'removes' do
      WatchlistStore.add('AAPL')
      WatchlistStore.add('MSFT')
      WatchlistStore.remove('AAPL')
      expect(WatchlistStore.read).to eq(['MSFT'])
    end
  end

  describe 'Watchlist API' do
    it 'POST rejects unknown symbols' do
      post '/api/watchlist', { symbol: 'ZZZZZ' }.to_json, { 'CONTENT_TYPE' => 'application/json' }
      expect(last_response.status).to eq(404)
    end

    it 'POST adds and GET returns the symbol' do
      post '/api/watchlist', { symbol: 'AAPL' }.to_json, { 'CONTENT_TYPE' => 'application/json' }
      expect(last_response).to be_ok
      get '/api/watchlist'
      body = JSON.parse(last_response.body)
      expect(body['symbols']).to include('AAPL')
    end

    it 'DELETE removes the symbol' do
      post '/api/watchlist', { symbol: 'AAPL' }.to_json, { 'CONTENT_TYPE' => 'application/json' }
      delete '/api/watchlist/AAPL'
      body = JSON.parse(last_response.body)
      expect(body['symbols']).to be_empty
    end
  end

  # ---- §4.4 Alerts -------------------------------------------------------
  describe 'AlertsStore' do
    it 'adds and reads an alert' do
      alert = AlertsStore.add(symbol: 'AAPL', condition: 'above', threshold: 200)
      expect(alert[:id]).to be_a(String)
      expect(AlertsStore.read.length).to eq(1)
      expect(AlertsStore.active.length).to eq(1)
    end

    it 'rejects invalid condition' do
      expect { AlertsStore.add(symbol: 'AAPL', condition: 'maybe', threshold: 10) }
        .to raise_error(ArgumentError)
    end

    it 'rejects non-positive threshold' do
      expect { AlertsStore.add(symbol: 'AAPL', condition: 'above', threshold: -1) }
        .to raise_error(ArgumentError)
    end

    it 'mark_triggered flips status and moves out of active' do
      a = AlertsStore.add(symbol: 'AAPL', condition: 'above', threshold: 200)
      AlertsStore.mark_triggered(a[:id], 205.0)
      expect(AlertsStore.active).to be_empty
      triggered = AlertsStore.read.first
      expect(triggered[:triggered_at]).not_to be_nil
      expect(triggered[:last_price]).to eq(205.0)
    end
  end

  describe 'Alerts API' do
    it 'POST creates an alert' do
      post '/api/alerts', { symbol: 'AAPL', condition: 'above', threshold: 200 }.to_json,
           { 'CONTENT_TYPE' => 'application/json' }
      expect(last_response).to be_ok
      alert = JSON.parse(last_response.body)
      expect(alert['id']).to be_a(String)
    end

    it 'GET filters by symbol' do
      post '/api/alerts', { symbol: 'AAPL', condition: 'above', threshold: 200 }.to_json,
           { 'CONTENT_TYPE' => 'application/json' }
      post '/api/alerts', { symbol: 'MSFT', condition: 'below', threshold: 300 }.to_json,
           { 'CONTENT_TYPE' => 'application/json' }

      get '/api/alerts?symbol=AAPL'
      body = JSON.parse(last_response.body)
      expect(body['alerts'].map { |a| a['symbol'] }.uniq).to eq(['AAPL'])
    end

    it 'POST returns 400 on invalid input' do
      post '/api/alerts', { symbol: 'AAPL', condition: 'sideways', threshold: 10 }.to_json,
           { 'CONTENT_TYPE' => 'application/json' }
      expect(last_response.status).to eq(400)
    end
  end

  # ---- §4.5 CSV export ---------------------------------------------------
  describe 'GET /api/export/:symbol/:period.csv' do
    it 'returns CSV with the expected header row' do
      get '/api/export/SPY/1y.csv'
      expect(last_response).to be_ok
      expect(last_response.content_type).to include('text/csv')
      first_line = last_response.body.lines.first
      expect(first_line).to include('date,open,high,low,close,adj_close,volume')
    end

    it '404s for unknown symbol' do
      get '/api/export/ZZZZZ/1y.csv'
      expect(last_response.status).to eq(404)
    end
  end

  # ---- §4.6 Compare ------------------------------------------------------
  describe 'GET /compare' do
    it 'renders the selection form with no symbols' do
      get '/compare'
      expect(last_response).to be_ok
      expect(last_response.body).to include('Compare')
    end

    it 'ignores unknown symbols and caps at 6' do
      get '/compare?symbols=AAPL,ZZZZZ,MSFT,GOOGL,AMZN,NVDA,JPM,TM,SONY'
      expect(last_response).to be_ok
      # shown list should be ≤6 and contain no ZZZZZ
      expect(last_response.body).not_to include('ZZZZZ')
    end
  end

  describe 'GET /api/compare' do
    it 'returns a series array rebased to 100 at first bar' do
      get '/api/compare?symbols=SPY&period=1y'
      expect(last_response).to be_ok
      body = JSON.parse(last_response.body)
      expect(body['series']).to be_an(Array)
      series = body['series'].first
      expect(series['symbol']).to eq('SPY')

      points = series['points']
      if points && !points.empty?
        expect(points.first['value']).to eq(100.0)
      end
    end
  end
end
