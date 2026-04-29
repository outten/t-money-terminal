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
      ENV['TRADES_PATH']      = File.join(dir, 'trades.json')
      ex.run
      %w[WATCHLIST_PATH ALERTS_PATH ALERTS_LOG_PATH PORTFOLIO_PATH TRADES_PATH].each { |k| ENV.delete(k) }
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
  # Portfolio (lot-based)
  # ----------------------------------------------------------------------------
  describe 'PortfolioStore (lot-based)' do
    it 'add_lot validates shares, cost_basis, and symbol' do
      expect { PortfolioStore.add_lot(symbol: 'AAPL', shares: 0,    cost_basis: 1) }.to raise_error(ArgumentError)
      expect { PortfolioStore.add_lot(symbol: 'AAPL', shares: 1,    cost_basis: 0) }.to raise_error(ArgumentError)
      expect { PortfolioStore.add_lot(symbol: '',    shares: 1,    cost_basis: 1) }.to raise_error(ArgumentError)
    end

    it 'add_lot accumulates rather than replacing' do
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 100, cost_basis: 150)
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 200, cost_basis: 175)
      lots = PortfolioStore.lots_for('AAPL')
      expect(lots.length).to eq(2)
      expect(lots.map { |l| l[:shares] }).to match_array([100, 200])
    end

    it 'find returns weighted-average aggregated position' do
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 100, cost_basis: 150)
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 100, cost_basis: 200)
      pos = PortfolioStore.find('AAPL')
      expect(pos[:shares]).to eq(200)
      expect(pos[:cost_basis]).to be_within(1e-4).of(175.0) # weighted avg
      expect(pos[:lots].length).to eq(2)
    end

    it 'remove deletes all lots for the symbol (typo-correction path)' do
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 100, cost_basis: 150)
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 50,  cost_basis: 175)
      PortfolioStore.remove('AAPL')
      expect(PortfolioStore.find('AAPL')).to be_nil
      expect(PortfolioStore.read).to be_empty
    end

    it 'remove_lot deletes a single lot by id' do
      first  = PortfolioStore.add_lot(symbol: 'AAPL', shares: 100, cost_basis: 150)
      _other = PortfolioStore.add_lot(symbol: 'AAPL', shares: 50,  cost_basis: 175)
      PortfolioStore.remove_lot(first[:id])
      expect(PortfolioStore.lots_for('AAPL').length).to eq(1)
    end
  end

  describe 'PortfolioStore.close_shares_fifo' do
    it 'fully closes the oldest lot when shares match exactly' do
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 100, cost_basis: 150, acquired_at: '2024-01-15')
      breakdown = PortfolioStore.close_shares_fifo(symbol: 'AAPL', shares: 100, price: 200)
      expect(breakdown[:realized_pl]).to eq(5000.00)
      expect(breakdown[:lots_closed].length).to eq(1)
      expect(PortfolioStore.find('AAPL')).to be_nil # all closed
    end

    it 'walks oldest-to-newest, splitting the last lot if partially closed' do
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 50, cost_basis: 100, acquired_at: '2024-01-01')
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 50, cost_basis: 110, acquired_at: '2024-02-01')
      breakdown = PortfolioStore.close_shares_fifo(symbol: 'AAPL', shares: 75, price: 120)
      # Closes 50 @ 100 ($1000 P&L) + 25 @ 110 ($250 P&L) = $1250
      expect(breakdown[:realized_pl]).to eq(1250.00)
      expect(breakdown[:lots_closed].length).to eq(2)

      # 25 shares @ $110 still open
      remaining = PortfolioStore.find('AAPL')
      expect(remaining[:shares]).to eq(25)
      expect(remaining[:cost_basis]).to be_within(1e-4).of(110.0)
    end

    it 'realises a loss when sale price < cost basis' do
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 100, cost_basis: 200)
      breakdown = PortfolioStore.close_shares_fifo(symbol: 'AAPL', shares: 100, price: 150)
      expect(breakdown[:realized_pl]).to eq(-5000.00)
    end

    it 'rejects sells that exceed total open shares' do
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 50, cost_basis: 100)
      expect {
        PortfolioStore.close_shares_fifo(symbol: 'AAPL', shares: 100, price: 110)
      }.to raise_error(ArgumentError, /only 50.0 open/)
    end

    it 'preserves closed lots in read() for audit while excluding from open_lots' do
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 100, cost_basis: 150)
      PortfolioStore.close_shares_fifo(symbol: 'AAPL', shares: 100, price: 200)
      expect(PortfolioStore.read.length).to eq(1)         # closed lot retained
      expect(PortfolioStore.read.first[:closed_at]).not_to be_nil
      expect(PortfolioStore.open_lots).to be_empty
    end
  end

  describe 'TradesStore' do
    it 'record_buy + record_sell append separate trades' do
      TradesStore.record_buy(symbol: 'AAPL', shares: 100, price: 150, date: '2024-01-15')
      breakdown = { symbol: 'AAPL', shares_closed: 100, price: 200, sold_at: '2024-06-01',
                    realized_pl: 5000.0, lots_closed: [{ lot_id: 'x', shares: 100, cost_basis: 150, realized_pl: 5000.0 }] }
      TradesStore.record_sell(breakdown)
      list = TradesStore.read
      expect(list.length).to eq(2)
      expect(list.map { |t| t[:side] }).to eq(%w[buy sell])
    end

    it 'realized_pl_total sums sells only' do
      TradesStore.record_buy(symbol: 'AAPL', shares: 100, price: 150)
      TradesStore.record_sell({ symbol: 'AAPL', shares_closed: 50, price: 200, sold_at: Date.today.iso8601, realized_pl: 2500.0,  lots_closed: [] })
      TradesStore.record_sell({ symbol: 'AAPL', shares_closed: 50, price: 100, sold_at: Date.today.iso8601, realized_pl: -2500.0, lots_closed: [] })
      expect(TradesStore.realized_pl_total).to eq(0.0)
    end

    it 'realized_pl_ytd filters to the current year' do
      this_year = Date.today.year
      TradesStore.record_sell({ symbol: 'AAPL', shares_closed: 10, price: 100, sold_at: "#{this_year - 1}-12-31", realized_pl: 999.0,  lots_closed: [] })
      TradesStore.record_sell({ symbol: 'AAPL', shares_closed: 10, price: 100, sold_at: "#{this_year}-01-15",     realized_pl: 1000.0, lots_closed: [] })
      expect(TradesStore.realized_pl_ytd).to eq(1000.00)
    end

    it 'for_symbol filters by symbol' do
      TradesStore.record_buy(symbol: 'AAPL', shares: 1, price: 1)
      TradesStore.record_buy(symbol: 'MSFT', shares: 1, price: 1)
      expect(TradesStore.for_symbol('AAPL').length).to eq(1)
      expect(TradesStore.for_symbol('MSFT').length).to eq(1)
    end
  end

  describe 'GET /portfolio (lot-based)' do
    it 'renders empty state when no positions' do
      get '/portfolio'
      expect(last_response).to be_ok
      expect(last_response.body).to include('No open positions')
    end

    it 'renders an aggregated row + lot detail for a multi-lot symbol' do
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 50,  cost_basis: 100, acquired_at: '2024-01-01')
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 100, cost_basis: 200, acquired_at: '2024-06-01')
      get '/portfolio'
      expect(last_response).to be_ok
      expect(last_response.body).to include('AAPL')
      expect(last_response.body).to include('lot-detail-row')   # expandable lots row exists
    end
  end

  describe 'POST /api/portfolio/buy + /sell' do
    it 'BUY creates a lot and records a trade' do
      header 'Content-Type', 'application/json'
      post '/api/portfolio/buy', { symbol: 'AAPL', shares: 100, cost_basis: 150 }.to_json
      expect(last_response).to be_ok
      expect(PortfolioStore.find('AAPL')).not_to be_nil
      expect(TradesStore.read.last[:side]).to eq('buy')
    end

    it 'BUY 404s on unknown symbol' do
      header 'Content-Type', 'application/json'
      post '/api/portfolio/buy', { symbol: 'ZZZZZ', shares: 10, cost_basis: 150 }.to_json
      expect(last_response.status).to eq(404)
    end

    it 'SELL closes shares FIFO and records a sell trade' do
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 100, cost_basis: 150)
      header 'Content-Type', 'application/json'
      post '/api/portfolio/sell', { symbol: 'AAPL', shares: 50, price: 200 }.to_json
      expect(last_response).to be_ok
      body = JSON.parse(last_response.body)
      expect(body['realized_pl']).to eq(2500.00)
      expect(TradesStore.read.last[:side]).to eq('sell')
      expect(PortfolioStore.find('AAPL')[:shares]).to eq(50)
    end

    it 'SELL 400s when shares > open' do
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 10, cost_basis: 150)
      header 'Content-Type', 'application/json'
      post '/api/portfolio/sell', { symbol: 'AAPL', shares: 100, price: 200 }.to_json
      expect(last_response.status).to eq(400)
    end
  end

  describe 'GET /trades' do
    it 'renders empty state when no trades' do
      get '/trades'
      expect(last_response).to be_ok
      expect(last_response.body).to include('No trades recorded')
    end

    it 'lists trades and shows realized P&L YTD card' do
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 100, cost_basis: 150)
      TradesStore.record_buy(symbol: 'AAPL', shares: 100, price: 150)
      breakdown = PortfolioStore.close_shares_fifo(symbol: 'AAPL', shares: 100, price: 200)
      TradesStore.record_sell(breakdown)
      get '/trades'
      expect(last_response).to be_ok
      expect(last_response.body).to include('AAPL')
      expect(last_response.body).to include('Realized P&amp;L (YTD)')
    end

    it 'filters by symbol' do
      TradesStore.record_buy(symbol: 'AAPL', shares: 1, price: 1)
      TradesStore.record_buy(symbol: 'MSFT', shares: 1, price: 1)
      get '/trades?symbol=AAPL'
      expect(last_response.body).to include('AAPL')
      expect(last_response.body).not_to match(/MSFT.*BUY/m)
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
