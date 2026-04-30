require 'rack/test'
require 'rspec'
require 'tmpdir'
require 'fileutils'
require 'json'

ENV['RACK_ENV'] = 'test'

require_relative '../app/main'

RSpec.describe 'Portfolio render is cache-only (no per-row network)' do
  include Rack::Test::Methods

  def app
    TMoneyTerminal
  end

  # Reset MarketDataService class state so the dev's real on-disk
  # market_cache.json doesn't leak into tests that exercise the
  # cache-fallback ordering. Snapshot/portfolio paths get tmpdirs.
  around(:each) do |ex|
    saved_cache       = MarketDataService.instance_variable_get(:@cache)
    saved_persistent  = MarketDataService.instance_variable_get(:@persistent_cache)
    saved_timestamps  = MarketDataService.instance_variable_get(:@cache_timestamps)
    MarketDataService.instance_variable_set(:@cache, {})
    MarketDataService.instance_variable_set(:@persistent_cache, {})
    MarketDataService.instance_variable_set(:@cache_timestamps, {})

    Dir.mktmpdir do |dir|
      ENV['IMPORT_SNAPSHOT_DIR'] = File.join(dir, 'imports')
      ENV['PORTFOLIO_PATH']      = File.join(dir, 'portfolio.json')
      ENV['TRADES_PATH']         = File.join(dir, 'trades.json')
      ENV['WATCHLIST_PATH']      = File.join(dir, 'watchlist.json')
      ENV['ALERTS_PATH']         = File.join(dir, 'alerts.json')
      ex.run
      %w[IMPORT_SNAPSHOT_DIR PORTFOLIO_PATH TRADES_PATH WATCHLIST_PATH ALERTS_PATH].each { |k| ENV.delete(k) }
    end
  ensure
    MarketDataService.instance_variable_set(:@cache,            saved_cache)
    MarketDataService.instance_variable_set(:@persistent_cache, saved_persistent)
    MarketDataService.instance_variable_set(:@cache_timestamps, saved_timestamps)
  end

  # --- 1. Live cache survives a "process restart" ---------------------------
  describe 'load_from_disk' do
    # Simulate a process boot by writing a known payload to a temp cache file,
    # pointing CACHE_FILE at it, wiping in-memory state, and re-running
    # load_from_disk. This tests the post-restart path — the user's actual
    # complaint — independent of whatever's in the dev cache on disk.
    it 'populates @cache (not just @persistent_cache) so read_live_cache hits after a restart' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'market_cache.json')
        payload = {
          'cache' => {
            'AAPL' => { '05. price' => '150.0', '10. change percent' => '+0.5%', '06. volume' => '0' }
          },
          'timestamps' => { 'AAPL' => Time.now.iso8601 }
        }
        File.write(path, JSON.generate(payload))

        # Wipe in-memory state.
        MarketDataService.instance_variable_set(:@cache, {})
        MarketDataService.instance_variable_set(:@persistent_cache, {})
        MarketDataService.instance_variable_set(:@cache_timestamps, {})

        stub_const('MarketDataService::CACHE_FILE', path)
        MarketDataService.send(:load_from_disk)

        # Both caches populated.
        expect(MarketDataService.instance_variable_get(:@persistent_cache)['AAPL']).not_to be_nil
        live = MarketDataService.instance_variable_get(:@cache)['AAPL']
        expect(live).not_to be_nil
        expect(live['05. price']).to eq('150.0')

        # And read_live_cache (what fetch_quote uses) hits — i.e. no provider
        # call would fire on the next /portfolio render after restart.
        ENV['MARKET_OPEN'] = '1' # pin TTL so freshness doesn't depend on wall-clock
        expect(MarketDataService.send(:read_live_cache, 'AAPL')).to eq(live)
      end
    ensure
      ENV.delete('MARKET_OPEN')
    end
  end

  # --- 2. analyst_cached is network-free ------------------------------------
  describe 'MarketDataService.analyst_cached' do
    it 'returns nil when nothing is cached and never fires Finnhub' do
      expect(MarketDataService).not_to receive(:fetch_analyst_recommendations)
      expect(Net::HTTP).not_to receive(:get_response)
      expect(MarketDataService.analyst_cached('NEVERFETCHED')).to be_nil
    end

    it 'returns the cached hash when present (live or persistent) without a network call' do
      key = 'analyst:AAPL'
      payload = { strong_buy: 12, buy: 5, hold: 3, sell: 1, strong_sell: 0 }
      MarketDataService.send(:store_cache, key, payload)
      expect(Net::HTTP).not_to receive(:get_response)
      expect(MarketDataService.analyst_cached('AAPL')).to eq(payload)
    end
  end

  # --- 3. signal_for cached_only never fires the analyst path ---------------
  describe 'RecommendationService.signal_for(cached_only: true)' do
    it 'never calls analyst_recommendations (the network-firing path)' do
      expect(MarketDataService).not_to receive(:analyst_recommendations)
      allow(MarketDataService).to receive(:analyst_cached).and_return(nil)
      allow(MarketDataService).to receive(:quote_cached).and_return('10. change percent' => '+1.5%')
      expect(RecommendationService.signal_for('AAPL', cached_only: true)).to eq('BUY')
    end

    it 'uses cached analyst data when present (no provider call)' do
      analyst = { strong_buy: 10, buy: 5, hold: 2, sell: 0, strong_sell: 0 }
      allow(MarketDataService).to receive(:analyst_cached).and_return(analyst)
      expect(MarketDataService).not_to receive(:analyst_recommendations)
      expect(RecommendationService.signal_for('AAPL', cached_only: true)).to eq('BUY')
    end

    it 'falls back to momentum signal from cached quote when analyst absent' do
      allow(MarketDataService).to receive(:analyst_cached).and_return(nil)
      allow(MarketDataService).to receive(:quote_cached).and_return('10. change percent' => '-1.5%')
      expect(RecommendationService.signal_for('NVDA', cached_only: true)).to eq('SELL')
    end

    it 'preserves the original signature (no kwarg) for the analyst-fetching path' do
      expect(MarketDataService).to receive(:analyst_recommendations).with('AAPL').and_return(nil)
      allow(MarketDataService).to receive(:quote).and_return('10. change percent' => '0%')
      RecommendationService.signal_for('AAPL')
    end
  end

  # --- 4. /portfolio render is fully cache-only ------------------------------
  describe 'GET /portfolio' do
    it 'never fires analyst_recommendations across all rendered rows' do
      # Three positions covering the common shapes.
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 10, cost_basis: 150.0)
      PortfolioStore.add_lot(symbol: 'NVDA', shares: 5,  cost_basis: 100.0)
      PortfolioStore.add_lot(symbol: 'VOO',  shares: 2,  cost_basis: 550.0)

      # Prime the quote cache (what the import would do).
      MarketDataService.prime_quote!('AAPL', price: 200.0, change_pct: 0.5, volume: 0)
      MarketDataService.prime_quote!('NVDA', price: 400.0, change_pct: -1.0, volume: 0)
      MarketDataService.prime_quote!('VOO',  price: 650.0, change_pct: 0.0, volume: 0)

      # Hard guarantee: analyst_recommendations (the network-firing path)
      # never gets called during the render.
      expect(MarketDataService).not_to receive(:analyst_recommendations)
      # And no raw HTTP either.
      expect(Net::HTTP).not_to receive(:get_response)

      get '/portfolio'
      expect(last_response).to be_ok
      # All three signal pills present.
      expect(last_response.body.scan(/signal-badge signal-(buy|sell|hold)/).length).to be >= 3
    end

    # The user's actual complaint: /portfolio loaded slowly an hour after
    # import because cache_entry_fresh? dropped the live entries and
    # fetch_quote re-ran the provider waterfall per row. With the new
    # quote_cached read, TTL is irrelevant for /portfolio rendering.
    it 'never fires fetch_quote even when the cache is stale' do
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 10, cost_basis: 150.0)
      MarketDataService.prime_quote!('AAPL', price: 200.0, change_pct: 0.5, volume: 0)

      # Forcibly age every timestamp past CACHE_TTL_CLOSED so cache_entry_fresh?
      # returns false unconditionally — exactly the post-1h-during-market-hours
      # scenario the user hit.
      stale = Time.now - (24 * 3600)
      MarketDataService.instance_variable_get(:@cache_timestamps).each_key do |k|
        MarketDataService.instance_variable_get(:@cache_timestamps)[k] = stale
      end

      expect(MarketDataService).not_to receive(:fetch_quote)
      expect(MarketDataService).not_to receive(:try_providers)
      expect(Net::HTTP).not_to receive(:get_response)

      get '/portfolio'
      expect(last_response).to be_ok
      expect(last_response.body).to include('AAPL')
      # Price still rendered from cache (or persistent fallback), not '—'.
      expect(last_response.body).to match(/\$200\.00/)
    end

    it 'falls back to the broker import snapshot when even @persistent_cache is empty' do
      PortfolioStore.add_lot(symbol: 'CMCSA', shares: 19, cost_basis: 259.80)
      # No prime_quote! — quote cache has nothing for CMCSA.
      ImportSnapshotStore.write(
        source: 'fidelity',
        basename: 'Portfolio_Positions_Apr-30-2026',
        data: {
          'file_date' => '2026-04-30',
          'positions' => [{
            'symbol' => 'CMCSA', 'shares' => 19, 'last_price' => 270.17,
            'day_change_pct' => -0.20, 'cost_basis' => 259.80, 'current_value' => 5133.23
          }]
        }
      )

      expect(Net::HTTP).not_to receive(:get_response)
      expect(MarketDataService).not_to receive(:try_providers)

      get '/portfolio'
      expect(last_response).to be_ok
      # Rendered from the snapshot price even with no cache entry.
      expect(last_response.body).to match(/\$270\.17/)
    end
  end

  # --- 5. quote_cached unit tests -------------------------------------------
  describe 'MarketDataService.quote_cached' do
    it 'returns the @cache entry when present (regardless of TTL)' do
      MarketDataService.prime_quote!('AAPL', price: 100.0, change_pct: 0, volume: 0)
      # Age the timestamp WAY past any TTL — quote_cached should still serve it.
      MarketDataService.instance_variable_get(:@cache_timestamps)['AAPL'] = Time.now - (10 * 24 * 3600)
      expect(MarketDataService.quote_cached('AAPL')['05. price']).to eq('100.0')
    end

    it 'falls back to @persistent_cache when @cache is empty' do
      MarketDataService.send(:store_cache, 'NVDA', { '05. price' => '450.0' })
      MarketDataService.instance_variable_get(:@cache).delete('NVDA') # simulate live-only eviction
      expect(MarketDataService.instance_variable_get(:@persistent_cache)['NVDA']).not_to be_nil
      expect(MarketDataService.quote_cached('NVDA')['05. price']).to eq('450.0')
    end

    it 'falls back to the broker snapshot when neither cache has the symbol' do
      ImportSnapshotStore.write(
        source: 'fidelity',
        basename: 'Portfolio_Positions_Apr-30-2026',
        data: { 'file_date' => '2026-04-30',
                'positions' => [{ 'symbol' => 'NEW', 'last_price' => 12.34,
                                  'day_change_pct' => 0, 'shares' => 1,
                                  'cost_basis' => 1, 'current_value' => 1 }] }
      )
      expect(MarketDataService.quote_cached('NEW')['05. price']).to eq('12.34')
    end

    it 'returns nil when nothing at all is known about the symbol' do
      expect(MarketDataService.quote_cached('ZZZZZZZ')).to be_nil
    end

    it 'never fires the provider waterfall' do
      expect(MarketDataService).not_to receive(:try_providers)
      expect(Net::HTTP).not_to receive(:get_response)
      MarketDataService.quote_cached('UNKNOWN')
    end
  end
end
