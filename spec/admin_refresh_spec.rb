require 'rack/test'
require 'rspec'
require 'tmpdir'
require 'fileutils'
require 'json'

ENV['RACK_ENV'] = 'test'

require_relative '../app/main'
require_relative '../app/refresh_tracker'

RSpec.describe 'FMP paywall tombstone + Admin refresh' do
  include Rack::Test::Methods

  def app
    TMoneyTerminal
  end

  around(:each) do |ex|
    Dir.mktmpdir do |dir|
      ENV['IMPORT_SNAPSHOT_DIR']     = File.join(dir, 'imports')
      ENV['PORTFOLIO_PATH']          = File.join(dir, 'portfolio.json')
      ENV['TRADES_PATH']             = File.join(dir, 'trades.json')
      ENV['WATCHLIST_PATH']          = File.join(dir, 'watchlist.json')
      ENV['SYMBOLS_EXTENDED_PATH']   = File.join(dir, 'symbols_extended.json')
      RefreshTracker.reset!
      ex.run
      RefreshTracker.reset!
      %w[IMPORT_SNAPSHOT_DIR PORTFOLIO_PATH TRADES_PATH WATCHLIST_PATH SYMBOLS_EXTENDED_PATH].each { |k| ENV.delete(k) }
    end
  end

  # =========================================================================
  # FMP paywall tombstone
  # =========================================================================
  describe 'Providers::FmpService paywall tombstone' do
    let!(:tmp_cache_root) { Dir.mktmpdir }

    before do
      # Redirect the cache root to a tmpdir so paywall files don't pollute
      # the dev's real data/cache/fmp/_paywalled_/ tree.
      stub_const('Providers::CacheStore::CACHE_ROOT', tmp_cache_root)
      # Force test_env? to false so the tombstone code actually writes/reads
      # to disk (it skips when RACK_ENV=test by default).
      allow(Providers::FmpService).to receive(:test_env?).and_return(false)
    end

    after { FileUtils.rm_rf(tmp_cache_root) }

    it 'writes a tombstone when the API returns 402' do
      # Provide a key so the env-var check passes.
      ENV['FMP_API_KEY'] = 'test-key'
      allow(Providers::HttpClient).to receive(:get_json).and_return([402, { 'Error Message' => 'Special Endpoint' }, ''])
      result = Providers::FmpService.key_metrics('FANUY', limit: 1)
      expect(result).to be_nil
      expect(Providers::FmpService.paywalled?('FANUY')).to be true
      expect(File.exist?(Providers::FmpService.paywall_path('FANUY'))).to be true
    ensure
      ENV.delete('FMP_API_KEY')
    end

    it 'short-circuits future calls without firing HTTP once tombstoned' do
      ENV['FMP_API_KEY'] = 'test-key'
      Providers::FmpService.mark_paywalled!('FANUY')
      expect(Providers::HttpClient).not_to receive(:get_json)
      expect(Providers::FmpService.ratios('FANUY', limit: 1)).to be_nil
      expect(Providers::FmpService.dcf('FANUY')).to be_nil
      expect(Providers::FmpService.key_metrics('FANUY')).to be_nil
    ensure
      ENV.delete('FMP_API_KEY')
    end

    it 'does not affect symbols that are not paywalled' do
      ENV['FMP_API_KEY'] = 'test-key'
      Providers::FmpService.mark_paywalled!('FANUY')
      payload = [{ 'symbol' => 'AAPL', 'marketCap' => 1_000_000 }]
      allow(Providers::HttpClient).to receive(:get_json).and_return([200, payload, ''])
      result = Providers::FmpService.key_metrics('AAPL', limit: 1)
      expect(result).not_to be_nil
      expect(result.first[:marketCap]).to eq(1_000_000)
    ensure
      ENV.delete('FMP_API_KEY')
    end

    it 'expires after PAYWALL_TTL so we re-test daily (in case FMP starts covering it)' do
      Providers::FmpService.mark_paywalled!('TESTSYM')
      File.utime(Time.now - (Providers::FmpService::PAYWALL_TTL + 60),
                 Time.now - (Providers::FmpService::PAYWALL_TTL + 60),
                 Providers::FmpService.paywall_path('TESTSYM'))
      expect(Providers::FmpService.paywalled?('TESTSYM')).to be false
    end
  end

  # =========================================================================
  # RefreshTracker
  # =========================================================================
  describe 'RefreshTracker' do
    it 'start! / tick / complete! transition through running → completed' do
      RefreshTracker.start!('all', total: 5)
      expect(RefreshTracker.running?('all')).to be true

      3.times { |i| RefreshTracker.tick('all', last_symbol: "SYM#{i}") }
      state = RefreshTracker.current('all')
      expect(state[:done]).to eq(3)
      expect(state[:last_symbol]).to eq('SYM2')

      RefreshTracker.complete!('all', ok: true)
      expect(RefreshTracker.running?('all')).to be false
      expect(RefreshTracker.current('all')[:status]).to eq('completed')
      expect(RefreshTracker.current('all')[:completed_at]).to be_a(Time)
    end

    it 'raises when start! is called for a job that is already running' do
      RefreshTracker.start!('all', total: 1)
      expect { RefreshTracker.start!('all') }.to raise_error(/already running/)
    end

    it 'allows restart after the previous run completed' do
      RefreshTracker.start!('all', total: 1)
      RefreshTracker.complete!('all')
      expect { RefreshTracker.start!('all', total: 2) }.not_to raise_error
    end

    it 'record_error caps the errors list to bound memory' do
      RefreshTracker.start!('all', total: 1000)
      80.times { |i| RefreshTracker.record_error('all', "S#{i}", 'boom') }
      expect(RefreshTracker.current('all')[:errors].length).to eq(50)
    end
  end

  # =========================================================================
  # Admin refresh routes
  # =========================================================================
  describe 'POST /admin/refresh/symbol' do
    it 'busts caches + refetches every layer for the given symbol' do
      expect(MarketDataService).to receive(:bust_cache_for_symbol!).with('AAPL')
      expect(MarketDataService).to receive(:quote).with('AAPL')
      expect(MarketDataService).to receive(:analyst_recommendations).with('AAPL')
      expect(MarketDataService).to receive(:company_profile).with('AAPL')
      expect(MarketDataService).to receive(:historical).with('AAPL', '1y')

      post '/admin/refresh/symbol', { 'symbol' => 'aapl' }
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include('refreshed=AAPL')
    end

    it '400s when symbol is missing' do
      post '/admin/refresh/symbol'
      expect(last_response.status).to eq(400)
    end
  end

  describe 'POST /admin/refresh/all' do
    it 'spawns a background refresh and redirects with refresh_started=all' do
      # Stub the universe so we don't iterate ~500 symbols in a test.
      allow(RefreshUniverse).to receive(:symbols).and_return(%w[AAPL NVDA])
      # Stub the per-symbol refresh fan-out so the thread completes quickly.
      allow(MarketDataService).to receive(:bust_cache_for_symbol!)
      allow(MarketDataService).to receive(:quote)
      allow(MarketDataService).to receive(:analyst_recommendations)
      allow(MarketDataService).to receive(:company_profile)
      allow(MarketDataService).to receive(:historical)

      post '/admin/refresh/all'
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include('refresh_started=all')

      # Drain the spawned worker.
      Thread.list.each { |t| t.join unless t == Thread.current }
      expect(RefreshTracker.current('all')[:status]).to eq('completed')
      expect(RefreshTracker.current('all')[:done]).to eq(2)
    end

    it 'redirects with refresh_busy=1 when one is already running' do
      RefreshTracker.start!('all', total: 1)
      post '/admin/refresh/all'
      expect(last_response.location).to include('refresh_busy=1')
    end
  end

  describe 'GET /admin/cache' do
    it 'shows the action forms (per-symbol input + Refresh ALL button)' do
      get '/admin/cache'
      expect(last_response).to be_ok
      expect(last_response.body).to include('action="/admin/refresh/symbol"')
      expect(last_response.body).to include('action="/admin/refresh/all"')
    end

    it 'renders the running banner while a refresh-all is in flight' do
      RefreshTracker.start!('all', total: 5)
      RefreshTracker.tick('all', last_symbol: 'AAPL')
      get '/admin/cache'
      expect(last_response.body).to include('Refresh ALL in progress')
      expect(last_response.body).to include('AAPL')
    end

    it 'renders a per-row refresh button on cache entries with a symbol' do
      MarketDataService.send(:store_cache, 'AAPL', { '05. price' => '100' })
      get '/admin/cache'
      expect(last_response.body).to match(/<form action="\/admin\/refresh\/symbol"/)
    end
  end

  describe 'GET /api/admin/refresh/status.json' do
    it 'returns the active job state' do
      RefreshTracker.start!('all', total: 3)
      RefreshTracker.tick('all', last_symbol: 'AAPL')
      get '/api/admin/refresh/status.json'
      expect(last_response).to be_ok
      body = JSON.parse(last_response.body)
      expect(body['status']).to eq('running')
      expect(body['total']).to eq(3)
      expect(body['done']).to eq(1)
      expect(body['last_symbol']).to eq('AAPL')
    end

    it '404s when no job has been started' do
      get '/api/admin/refresh/status.json'
      expect(last_response.status).to eq(404)
    end
  end
end
