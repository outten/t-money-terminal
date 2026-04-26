require 'rack/test'
require 'rspec'
require 'tmpdir'
require 'json'

ENV['RACK_ENV'] = 'test'

require_relative '../app/main'
require_relative '../app/notifiers'

RSpec.describe 'Newly added features' do
  include Rack::Test::Methods

  def app
    TMoneyTerminal
  end

  around(:each) do |ex|
    Dir.mktmpdir do |dir|
      ENV['WATCHLIST_PATH']   = File.join(dir, 'watchlist.json')
      ENV['ALERTS_PATH']      = File.join(dir, 'alerts.json')
      ENV['ALERTS_LOG_PATH']  = File.join(dir, 'alerts.log')
      ENV['PORTFOLIO_PATH']   = File.join(dir, 'portfolio.json')
      ex.run
      %w[WATCHLIST_PATH ALERTS_PATH ALERTS_LOG_PATH PORTFOLIO_PATH].each { |k| ENV.delete(k) }
    end
  end

  # ----------------------------------------------------------------------------
  # #5  Provider health
  # ----------------------------------------------------------------------------
  describe 'HealthRegistry' do
    around(:each) do |ex|
      ENV['HEALTH_REGISTRY'] = '1'
      HealthRegistry.reset!
      ex.run
      HealthRegistry.reset!
      ENV.delete('HEALTH_REGISTRY')
    end

    it 'records ok and error observations and computes a success rate' do
      HealthRegistry.record(provider: 'demo', status: :ok,    http_status: 200, latency_ms: 10)
      HealthRegistry.record(provider: 'demo', status: :ok,    http_status: 200, latency_ms: 20)
      HealthRegistry.record(provider: 'demo', status: :error, reason: 'rate_limited', http_status: 429)

      row = HealthRegistry.summary.find { |r| r[:provider] == 'demo' }
      expect(row[:total]).to eq(3)
      expect(row[:ok]).to eq(2)
      expect(row[:error]).to eq(1)
      expect(row[:success_rate]).to be_within(0.01).of(0.667)
      expect(row[:last_error_reason]).to eq('rate_limited')
      expect(row[:avg_latency_ms]).to be_a(Integer)
    end

    it 'measure() records :ok on truthy result and :error on nil' do
      HealthRegistry.measure('demo') { 42 }
      HealthRegistry.measure('demo') { nil }
      row = HealthRegistry.summary.find { |r| r[:provider] == 'demo' }
      expect(row[:ok]).to eq(1)
      expect(row[:error]).to eq(1)
    end

    it 'measure() records :error on raised exceptions and re-raises' do
      expect {
        HealthRegistry.measure('demo') { raise 'boom' }
      }.to raise_error(RuntimeError, 'boom')
      row = HealthRegistry.summary.find { |r| r[:provider] == 'demo' }
      expect(row[:error]).to eq(1)
      expect(row[:last_error_reason]).to include('RuntimeError')
    end

    it 'caps observations per provider at CAPACITY' do
      (HealthRegistry::CAPACITY + 50).times do
        HealthRegistry.record(provider: 'demo', status: :ok)
      end
      row = HealthRegistry.summary.find { |r| r[:provider] == 'demo' }
      expect(row[:total]).to eq(HealthRegistry::CAPACITY)
    end
  end

  describe 'GET /admin/health' do
    it 'renders the page and the JSON variant' do
      get '/admin/health'
      expect(last_response).to be_ok
      expect(last_response.body).to include('Provider Health')

      get '/api/admin/health.json'
      expect(last_response).to be_ok
      body = JSON.parse(last_response.body)
      expect(body).to have_key('providers')
    end
  end

  # ----------------------------------------------------------------------------
  # #4 Dividend-adjusted close
  # ----------------------------------------------------------------------------
  describe 'Analytics::Risk' do
    it 'closes_from prefers adj_close when total_return: true and falls back to close' do
      bars = [
        { date: '2024-01-01', close: 100.0, adj_close: 95.0 },
        { date: '2024-01-02', close: 110.0 } # missing adj_close → falls back
      ]
      adj = Analytics::Risk.closes_from(bars, total_return: true)
      raw = Analytics::Risk.closes_from(bars, total_return: false)
      expect(adj).to eq([95.0, 110.0])
      expect(raw).to eq([100.0, 110.0])
    end

    it 'align_on_dates uses adj_close when field: :adj_close' do
      a = [{ date: 'D1', close: 10.0, adj_close: 9.0 }, { date: 'D2', close: 12.0, adj_close: 11.0 }]
      b = [{ date: 'D1', close: 50.0, adj_close: 45.0 }, { date: 'D2', close: 60.0, adj_close: 55.0 }]
      ax, bx = Analytics::Risk.align_on_dates(a, b, field: :adj_close)
      expect(ax).to eq([9.0, 11.0])
      expect(bx).to eq([45.0, 55.0])
    end
  end

  describe 'CSV export' do
    it 'includes adj_close in the header' do
      get '/api/export/SPY/1y.csv'
      expect(last_response).to be_ok
      header = last_response.body.lines.first
      expect(header).to include('adj_close')
    end
  end

  # ----------------------------------------------------------------------------
  # #1 Portfolio
  # ----------------------------------------------------------------------------
  describe 'PortfolioStore' do
    it 'upsert validates shares and cost_basis' do
      expect { PortfolioStore.upsert(symbol: 'AAPL', shares: 0,    cost_basis: 1) }.to raise_error(ArgumentError)
      expect { PortfolioStore.upsert(symbol: 'AAPL', shares: 1,    cost_basis: 0) }.to raise_error(ArgumentError)
      expect { PortfolioStore.upsert(symbol: '',    shares: 1,    cost_basis: 1) }.to raise_error(ArgumentError)
    end

    it 'upsert replaces rather than duplicates' do
      PortfolioStore.upsert(symbol: 'AAPL', shares: 100, cost_basis: 150)
      PortfolioStore.upsert(symbol: 'AAPL', shares: 200, cost_basis: 175)
      list = PortfolioStore.read
      expect(list.length).to eq(1)
      expect(list.first[:shares]).to eq(200)
      expect(list.first[:cost_basis]).to eq(175)
    end

    it 'remove deletes the holding' do
      PortfolioStore.upsert(symbol: 'AAPL', shares: 100, cost_basis: 150)
      PortfolioStore.remove('AAPL')
      expect(PortfolioStore.read).to be_empty
    end

    it 'find returns the stored holding' do
      PortfolioStore.upsert(symbol: 'AAPL', shares: 100, cost_basis: 150)
      h = PortfolioStore.find('aapl')
      expect(h[:symbol]).to eq('AAPL')
      expect(h[:shares]).to eq(100)
    end
  end

  describe 'GET /portfolio' do
    it 'renders empty state when no holdings' do
      get '/portfolio'
      expect(last_response).to be_ok
      expect(last_response.body).to include('No holdings yet')
    end

    it 'renders rows for stored holdings' do
      PortfolioStore.upsert(symbol: 'AAPL', shares: 10, cost_basis: 150)
      get '/portfolio'
      expect(last_response).to be_ok
      expect(last_response.body).to include('AAPL')
    end
  end

  describe 'POST /api/portfolio' do
    it 'creates a holding for a known symbol' do
      header 'Content-Type', 'application/json'
      post '/api/portfolio', { symbol: 'AAPL', shares: 10, cost_basis: 150 }.to_json
      expect(last_response).to be_ok
      expect(PortfolioStore.find('AAPL')).not_to be_nil
    end

    it '404s on unknown symbol' do
      header 'Content-Type', 'application/json'
      post '/api/portfolio', { symbol: 'ZZZZZ', shares: 10, cost_basis: 150 }.to_json
      expect(last_response.status).to eq(404)
    end

    it '400s on invalid input' do
      header 'Content-Type', 'application/json'
      post '/api/portfolio', { symbol: 'AAPL', shares: 0, cost_basis: 150 }.to_json
      expect(last_response.status).to eq(400)
    end
  end

  # ----------------------------------------------------------------------------
  # #3 Alert notifications
  # ----------------------------------------------------------------------------
  describe 'Notifiers' do
    it 'configured_channels reflects env vars' do
      ENV['ALERT_NTFY_TOPIC']   = 'demo'
      ENV['ALERT_WEBHOOK_URL']  = ''
      ENV['ALERT_EMAIL_TO']     = nil
      expect(Notifiers.configured_channels).to eq([:ntfy])
    ensure
      %w[ALERT_NTFY_TOPIC ALERT_WEBHOOK_URL ALERT_EMAIL_TO].each { |k| ENV.delete(k) }
    end

    it 'dispatch returns one result per configured channel and isolates failures' do
      ENV['ALERT_NTFY_TOPIC'] = 'demo-topic'
      allow(Notifiers).to receive(:send_ntfy).and_raise('upstream down')
      results = Notifiers.dispatch(symbol: 'AAPL', condition: 'above', threshold: 100, last_price: 105)
      expect(results.length).to eq(1)
      expect(results.first[:channel]).to eq(:ntfy)
      expect(results.first[:ok]).to be false
      expect(results.first[:error]).to include('upstream down')
    ensure
      ENV.delete('ALERT_NTFY_TOPIC')
    end

    it 'dispatch is a no-op when nothing is configured' do
      expect(Notifiers.dispatch(symbol: 'AAPL', condition: 'above', threshold: 100, last_price: 105)).to eq([])
    end
  end
end
