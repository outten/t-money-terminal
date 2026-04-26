require 'rack/test'
require 'rspec'
require 'tmpdir'
require 'json'

ENV['RACK_ENV'] = 'test'

require_relative '../app/main'

RSpec.describe 'Tier 1 — dynamic symbols + heatmap + health banner + CSV period' do
  include Rack::Test::Methods

  def app
    TMoneyTerminal
  end

  # Each example gets fresh tmp paths for every file-backed store, plus a
  # clean SymbolIndex extension cache so tests don't leak runtime state.
  around(:each) do |ex|
    Dir.mktmpdir do |dir|
      ENV['WATCHLIST_PATH']        = File.join(dir, 'watchlist.json')
      ENV['ALERTS_PATH']           = File.join(dir, 'alerts.json')
      ENV['ALERTS_LOG_PATH']       = File.join(dir, 'alerts.log')
      ENV['PORTFOLIO_PATH']        = File.join(dir, 'portfolio.json')
      ENV['SYMBOLS_EXTENDED_PATH'] = File.join(dir, 'symbols_extended.json')
      SymbolIndex.reset_extensions!
      ex.run
      SymbolIndex.reset_extensions!
      %w[WATCHLIST_PATH ALERTS_PATH ALERTS_LOG_PATH PORTFOLIO_PATH SYMBOLS_EXTENDED_PATH].each { |k| ENV.delete(k) }
    end
  end

  # ============================================================================
  # A. Dynamic symbol universe
  # ============================================================================
  describe 'SymbolIndex.add_extension' do
    it 'persists, makes the symbol known?, and survives a reload' do
      SymbolIndex.add_extension('PLTR', name: 'Palantir Technologies', region: 'US')
      expect(SymbolIndex.known?('PLTR')).to be true
      expect(SymbolIndex.symbols).to include('PLTR')

      # Force a reload from disk.
      SymbolIndex.send(:invalidate_caches!)
      expect(SymbolIndex.known?('PLTR')).to be true
    end

    it 'is idempotent — adding the same symbol twice is a no-op' do
      first  = SymbolIndex.add_extension('PLTR', name: 'Palantir Technologies')
      second = SymbolIndex.add_extension('PLTR', name: 'something else')
      expect(second[:name]).to eq(first[:name]) # original wins
      expect(SymbolIndex.symbols.count('PLTR')).to eq(1)
    end

    it 'normalizes to uppercase' do
      SymbolIndex.add_extension('pltr', name: 'Palantir')
      expect(SymbolIndex.known?('PLTR')).to be true
      expect(SymbolIndex.known?('pltr')).to be true
    end

    it 'rejects empty symbols' do
      expect { SymbolIndex.add_extension('', name: 'X') }.to raise_error(ArgumentError)
    end
  end

  describe 'SymbolIndex.looks_like_ticker?' do
    it 'accepts canonical tickers' do
      %w[AAPL BRK.B BRK-B Z X].each { |s| expect(SymbolIndex.looks_like_ticker?(s)).to be(true), "#{s} should look like ticker" }
    end

    it 'rejects garbage' do
      ['', 'aapl is great', 'this is not a symbol', '123ABC', 'A!B'].each do |s|
        expect(SymbolIndex.looks_like_ticker?(s)).to be(false), "#{s.inspect} should not look like ticker"
      end
    end
  end

  describe 'GET /api/symbols' do
    it 'returns can_discover: true when query has no match but looks like a ticker' do
      get '/api/symbols?q=ZZZZ'
      expect(last_response).to be_ok
      body = JSON.parse(last_response.body)
      expect(body['results']).to be_empty
      expect(body['can_discover']).to be true
      expect(body['query']).to eq('ZZZZ')
    end

    it 'returns can_discover: false when query is junk' do
      get '/api/symbols?q=this+is+not+a+symbol'
      body = JSON.parse(last_response.body)
      expect(body['can_discover']).to be false
    end

    it 'returns can_discover: false when query already matches' do
      get '/api/symbols?q=AAPL'
      body = JSON.parse(last_response.body)
      expect(body['results']).not_to be_empty
      expect(body['can_discover']).to be false
    end

    it 'includes user-added extensions in search results' do
      SymbolIndex.add_extension('PLTR', name: 'Palantir Technologies', region: 'US')
      get '/api/symbols?q=PLTR'
      body = JSON.parse(last_response.body)
      expect(body['results'].map { |r| r['symbol'] }).to include('PLTR')
    end
  end

  describe 'POST /api/symbols/discover' do
    it 'rejects garbage with 400' do
      header 'Content-Type', 'application/json'
      post '/api/symbols/discover', { symbol: 'this is junk' }.to_json
      expect(last_response.status).to eq(400)
    end

    it 'returns already_known: true for symbols already in the index without hitting any provider' do
      header 'Content-Type', 'application/json'
      post '/api/symbols/discover', { symbol: 'AAPL' }.to_json
      expect(last_response).to be_ok
      body = JSON.parse(last_response.body)
      expect(body['symbol']).to eq('AAPL')
      expect(body['already_known']).to be true
    end

    it '404s when the quote waterfall returns no price' do
      allow(MarketDataService).to receive(:quote).and_return({ '05. price' => '0' })
      header 'Content-Type', 'application/json'
      post '/api/symbols/discover', { symbol: 'ZZZZ' }.to_json
      expect(last_response.status).to eq(404)
      expect(SymbolIndex.known?('ZZZZ')).to be false # not persisted on failure
    end

    it 'persists the symbol on a successful quote' do
      allow(MarketDataService).to receive(:quote).and_return({ '05. price' => '42.50' })
      allow(MarketDataService).to receive(:company_profile).and_return({ name: 'Discoverable Inc.', exchange: 'NASDAQ' })
      header 'Content-Type', 'application/json'
      post '/api/symbols/discover', { symbol: 'DISC' }.to_json
      expect(last_response).to be_ok
      body = JSON.parse(last_response.body)
      expect(body['symbol']).to eq('DISC')
      expect(body['name']).to eq('Discoverable Inc.')
      expect(SymbolIndex.known?('DISC')).to be true
    end

    it 'tolerates a missing profile and falls back to symbol-as-name' do
      allow(MarketDataService).to receive(:quote).and_return({ '05. price' => '42.50' })
      allow(MarketDataService).to receive(:company_profile).and_return(nil)
      header 'Content-Type', 'application/json'
      post '/api/symbols/discover', { symbol: 'BARE' }.to_json
      expect(last_response).to be_ok
      body = JSON.parse(last_response.body)
      expect(body['name']).to eq('BARE')
      expect(SymbolIndex.known?('BARE')).to be true
    end
  end

  describe '/analysis/:symbol with discovered ticker' do
    it 'serves the page for a runtime-discovered symbol' do
      SymbolIndex.add_extension('DISC', name: 'Discoverable Inc.', region: 'NASDAQ')
      allow(MarketDataService).to receive(:quote).and_return({ '05. price' => '42.50' })
      allow(MarketDataService).to receive(:analyst_recommendations).and_return(nil)
      allow(MarketDataService).to receive(:company_profile).and_return({ name: 'Discoverable Inc.' })
      allow(MarketDataService).to receive(:historical).and_return([])
      get '/analysis/DISC'
      expect(last_response.status).to eq(200).or eq(302) # may redirect on edge, but should not 404
    end
  end

  describe 'historical waterfall — Polygon fallback (regression for symbols FMP paywalls)' do
    # The waterfall must include Polygon. Without it, symbols that FMP paywalls
    # (CMCSA, BRK.B, smaller-caps) and that Yahoo IP-throttles silently leave
    # the user with a blank chart. This regression test pins the order.
    it 'wires Polygon into the per-period historical waterfall' do
      src = File.read(File.expand_path('../app/market_data_service.rb', __dir__))
      expect(src).to include("HealthRegistry.measure('polygon_history'")
      expect(src).to include('fetch_historical_from_polygon')
    end

    it 'wires Polygon into the prefetch_all_historical bulk path' do
      src = File.read(File.expand_path('../app/market_data_service.rb', __dir__))
      expect(src).to match(/Providers::PolygonService\.daily_aggregates/)
    end

    it 'fetch_historical_from_polygon translates Polygon string-keyed bars into MDS symbol-keyed bars' do
      stub = [{ 'date' => '2024-04-01', 'open' => 30.0, 'high' => 31.0, 'low' => 29.5, 'close' => 30.5, 'volume' => 1_000_000 }]
      allow(Providers::PolygonService).to receive(:daily_aggregates).and_return(stub)
      bars = MarketDataService.send(:fetch_historical_from_polygon, 'CMCSA', '1y')
      expect(bars.length).to eq(1)
      expect(bars.first[:date]).to eq('2024-04-01')
      expect(bars.first[:close]).to eq(30.5)
      expect(bars.first[:adj_close]).to eq(30.5)
      expect(bars.first[:volume]).to eq(1_000_000)
    end

    it 'returns nil when Polygon returns no bars' do
      allow(Providers::PolygonService).to receive(:daily_aggregates).and_return([])
      expect(MarketDataService.send(:fetch_historical_from_polygon, 'CMCSA', '1y')).to be_nil
    end
  end

  # ============================================================================
  # B. Correlation heatmap
  # ============================================================================
  describe 'Analytics::Risk.correlation_matrix' do
    it 'returns 1.0 on the diagonal and is symmetric' do
      bars = (1..30).map { |i| { date: "2024-01-#{format('%02d', i)}", close: 100.0 + i, adj_close: 100.0 + i } }
      bars2 = (1..30).map { |i| { date: "2024-01-#{format('%02d', i)}", close: 200.0 + i * 0.5, adj_close: 200.0 + i * 0.5 } }
      result = Analytics::Risk.correlation_matrix({ 'A' => bars, 'B' => bars2 })

      expect(result[:symbols]).to eq(['A', 'B'])
      expect(result[:matrix][0][0]).to eq(1.0)
      expect(result[:matrix][1][1]).to eq(1.0)
      expect(result[:matrix][0][1]).to be_within(1e-9).of(result[:matrix][1][0])
    end

    it 'emits 1.0 (perfect correlation) for identical series' do
      bars = (1..20).map { |i| { date: "2024-02-#{format('%02d', i)}", close: 50.0 + i, adj_close: 50.0 + i } }
      result = Analytics::Risk.correlation_matrix({ 'X' => bars, 'Y' => bars })
      expect(result[:matrix][0][1]).to be_within(1e-9).of(1.0)
    end

    it 'returns nil cells when alignment yields fewer than 2 common dates' do
      a = [{ date: '2024-01-01', close: 100.0 }, { date: '2024-01-02', close: 101.0 }]
      b = [{ date: '2099-01-01', close: 50.0 }] # no overlap
      result = Analytics::Risk.correlation_matrix({ 'A' => a, 'B' => b })
      expect(result[:matrix][0][1]).to be_nil
      expect(result[:matrix][1][0]).to be_nil
    end
  end

  describe 'CorrelationStore' do
    it 'builds the same cache key regardless of input order' do
      k1 = CorrelationStore.send(:build_key, %w[AAPL MSFT GOOGL], '1y')
      k2 = CorrelationStore.send(:build_key, %w[GOOGL AAPL MSFT], '1y')
      expect(k1).to eq(k2)
    end

    it 'incorporates the period into the cache key' do
      k1 = CorrelationStore.send(:build_key, %w[AAPL MSFT], '1y')
      k2 = CorrelationStore.send(:build_key, %w[AAPL MSFT], '5y')
      expect(k1).not_to eq(k2)
    end

    it 'returns an empty payload for empty input' do
      payload = CorrelationStore.matrix_for([], period: '1y')
      expect(payload['symbols']).to be_empty
      expect(payload['matrix']).to be_empty
    end

    it 'computes the matrix from MarketDataService.historical' do
      bars = (1..15).map { |i| { date: "2024-03-#{format('%02d', i)}", close: 10.0 + i, adj_close: 10.0 + i } }
      allow(MarketDataService).to receive(:historical).and_return(bars)
      payload = CorrelationStore.matrix_for(%w[SPY QQQ], period: '1y')
      expect(payload['symbols']).to eq(%w[SPY QQQ])
      expect(payload['matrix'][0][0]).to eq(1.0)
    end
  end

  describe 'GET /api/correlations' do
    before do
      bars = (1..15).map { |i| { date: "2024-03-#{format('%02d', i)}", close: 10.0 + i, adj_close: 10.0 + i } }
      allow(MarketDataService).to receive(:historical).and_return(bars)
    end

    it 'returns symbols + matrix for a valid request' do
      get '/api/correlations?symbols=SPY,QQQ&period=1y'
      expect(last_response).to be_ok
      body = JSON.parse(last_response.body)
      expect(body['symbols']).to eq(%w[SPY QQQ])
      expect(body['matrix'].length).to eq(2)
      expect(body['matrix'][0][0]).to eq(1.0)
    end

    it '400s with fewer than two known symbols' do
      get '/api/correlations?symbols=SPY'
      expect(last_response.status).to eq(400)
    end

    it '400s with too many symbols' do
      ids = (1..(TMoneyTerminal::CORRELATION_MAX_SYMBOLS + 2)).map { |i| "S#{i}" }
      ids.each { |s| SymbolIndex.add_extension(s, name: s, region: 'US') }
      get "/api/correlations?symbols=#{ids.join(',')}"
      expect(last_response.status).to eq(400)
    end

    it 'silently drops unknown symbols and proceeds with what remains' do
      get '/api/correlations?symbols=SPY,UNKNOWNX,QQQ'
      expect(last_response).to be_ok
      body = JSON.parse(last_response.body)
      expect(body['symbols']).to eq(%w[SPY QQQ])
    end
  end

  describe 'GET /correlations' do
    it 'renders the selection form when no symbols given' do
      get '/correlations'
      expect(last_response).to be_ok
      expect(last_response.body).to include('Correlations')
    end

    it 'renders the heatmap as an HTML table for >=2 symbols' do
      bars = (1..15).map { |i| { date: "2024-03-#{format('%02d', i)}", close: 10.0 + i, adj_close: 10.0 + i } }
      allow(MarketDataService).to receive(:historical).and_return(bars)
      get '/correlations?symbols=SPY,QQQ&period=1y'
      expect(last_response).to be_ok
      expect(last_response.body).to include('class="corr-heatmap"')
      expect(last_response.body).to include('class="corr-cell"')
      # Column / row labels for both symbols.
      expect(last_response.body.scan(/<th class="corr-row-label"[^>]*>SPY<\/th>/).length).to eq(1)
      expect(last_response.body.scan(/<th class="corr-row-label"[^>]*>QQQ<\/th>/).length).to eq(1)
      # Diagonal must be 1.00 — content sits between the <td> and </td> tags.
      expect(last_response.body).to match(/<td class="corr-cell"[^>]*>\s*1\.00\s*<\/td>/)
    end

    it 'renders missing-cell placeholder when a pair has no overlap' do
      a = (1..5).map  { |i| { date: "2024-01-#{format('%02d', i)}", close: 10.0 + i, adj_close: 10.0 + i } }
      b = (1..5).map  { |i| { date: "2099-01-#{format('%02d', i)}", close: 50.0 + i, adj_close: 50.0 + i } }
      allow(MarketDataService).to receive(:historical) do |sym, _|
        sym == 'AAPL' ? a : b
      end
      get '/correlations?symbols=AAPL,MSFT&period=1y'
      expect(last_response).to be_ok
      # Off-diagonal cell with em-dash for the no-overlap pair.
      expect(last_response.body).to match(/<td class="corr-cell"[^>]*>\s*—\s*<\/td>/)
    end
  end

  describe 'correlation cell colors (server-rendered)' do
    # Identical-trending series → +1 → bright green background. Stub historical
    # so identical bars come back for both symbols.
    it 'paints diagonal cells with the +1 (green) color' do
      bars = (1..20).map { |i| { date: "2024-04-#{format('%02d', i)}", close: 10.0 + i, adj_close: 10.0 + i } }
      allow(MarketDataService).to receive(:historical).and_return(bars)
      get '/correlations?symbols=SPY,QQQ&period=1y'
      # The diagonal cells are painted with rgb(52, 199, 89) — pure green.
      expect(last_response.body).to include('background:rgb(52, 199, 89)')
    end

    it 'renders a cell color and contrasting text color for every cell' do
      bars = (1..20).map { |i| { date: "2024-04-#{format('%02d', i)}", close: 10.0 + i, adj_close: 10.0 + i } }
      allow(MarketDataService).to receive(:historical).and_return(bars)
      get '/correlations?symbols=SPY,QQQ&period=1y'
      # Every td.corr-cell carries inline background + color.
      cells = last_response.body.scan(/<td class="corr-cell"[^>]*style="([^"]+)"/).flatten
      expect(cells.length).to eq(4) # 2x2
      cells.each do |style|
        expect(style).to match(/background:\s*(rgb\([^)]+\)|#[0-9a-f]{6})/i)
        expect(style).to match(/color:\s*#(?:1d1d1f|ffffff)/i)
      end
    end
  end

  # ============================================================================
  # D. Provider degradation banner
  # ============================================================================
  describe 'HealthRegistry.degraded' do
    around(:each) do |ex|
      ENV['HEALTH_REGISTRY'] = '1'
      HealthRegistry.reset!
      ex.run
      HealthRegistry.reset!
      ENV.delete('HEALTH_REGISTRY')
    end

    it 'returns providers with success_rate < threshold and >= min observations' do
      6.times { HealthRegistry.record(provider: 'flaky',  status: :error, reason: 'rate_limited') }
      1.times { HealthRegistry.record(provider: 'flaky',  status: :ok) }
      6.times { HealthRegistry.record(provider: 'healthy', status: :ok) }
      degraded = HealthRegistry.degraded
      expect(degraded.map { |p| p[:provider] }).to eq(['flaky'])
    end

    it 'ignores providers with too few observations to judge' do
      2.times { HealthRegistry.record(provider: 'fresh', status: :error) }
      expect(HealthRegistry.degraded).to be_empty
    end

    it 'returns [] when nothing is degraded' do
      10.times { HealthRegistry.record(provider: 'good', status: :ok) }
      expect(HealthRegistry.degraded).to be_empty
    end
  end

  describe 'GET /dashboard with degraded providers' do
    # The dashboard route exercises real providers against the user's
    # .credentials, which would interleave fresh observations with anything
    # we pre-record here. So we stub `HealthRegistry.degraded` to assert the
    # view wiring deterministically. The threshold/min_observations logic is
    # covered by the unit tests above.

    it 'renders the degradation banner when degraded() reports any provider' do
      fake_row = {
        provider:    'tiingo_quote',
        total:       8,
        ok:          1,
        error:       7,
        success_rate: 0.125,
        last_ok_at:  nil,
        last_error_at: Time.now,
        last_error_reason: 'rate_limited',
        last_http_status: 429,
        avg_latency_ms: 100
      }
      allow(HealthRegistry).to receive(:degraded).and_return([fake_row])
      get '/dashboard'
      expect(last_response).to be_ok
      expect(last_response.body).to include('Provider degradation')
      expect(last_response.body).to include('tiingo_quote')
      expect(last_response.body).to include('13%') # rounded 0.125 * 100
    end

    it 'does NOT render the banner when degraded() reports nothing' do
      allow(HealthRegistry).to receive(:degraded).and_return([])
      get '/dashboard'
      expect(last_response.body).not_to include('Provider degradation')
    end
  end

  # ============================================================================
  # C. CSV export honors current chart period
  # ============================================================================
  describe 'GET /analysis/:symbol — CSV export button wiring' do
    before do
      # Stub everything the analysis route touches so we can assert on markup.
      allow(MarketDataService).to receive(:quote).and_return({ '05. price' => '150.0' })
      allow(MarketDataService).to receive(:analyst_recommendations).and_return(nil)
      allow(MarketDataService).to receive(:company_profile).and_return({ name: 'Apple Inc.' })
      allow(MarketDataService).to receive(:historical).and_return([])
      allow(MarketDataService).to receive(:cache_info_for).and_return(cached_at: nil, is_stale: false)
    end

    it 'exposes a stable id and data attributes the period toggle can update' do
      get '/analysis/AAPL'
      expect(last_response).to be_ok
      expect(last_response.body).to include('id="export-csv-btn"')
      expect(last_response.body).to include('data-symbol="AAPL"')
      expect(last_response.body).to include('data-period="1y"')
    end

    it 'renders the period label in the button text' do
      get '/analysis/AAPL'
      expect(last_response.body).to include('export-csv-period')
      expect(last_response.body).to match(/<span class="export-csv-period">1Y<\/span>/)
    end

    it 'initial href points to the 1y CSV (matches default chart period)' do
      get '/analysis/AAPL'
      expect(last_response.body).to include('href="/api/export/AAPL/1y.csv"')
    end

    it 'includes the syncExportButton helper so the period toggle can update the link' do
      get '/analysis/AAPL'
      expect(last_response.body).to include('syncExportButton')
    end
  end

  # The route side has accepted every period since CSV export was first
  # introduced — verify each is reachable and 200s for a known symbol.
  describe 'GET /api/export/:symbol/:period.csv across all periods' do
    %w[1d 1m 3m ytd 1y 5y].each do |period|
      it "serves CSV for period=#{period}" do
        get "/api/export/AAPL/#{period}.csv"
        expect(last_response).to be_ok
        expect(last_response.content_type).to include('text/csv')
      end
    end

    it '400s on an unsupported period' do
      get '/api/export/AAPL/10y.csv'
      expect(last_response.status).to eq(400)
    end
  end
end
