require 'sinatra'
require 'dotenv'
Dotenv.load(File.expand_path('../../.credentials', __FILE__))
require 'json'
require 'csv'
require 'date'
require 'set'
require_relative 'market_data_service'
require_relative 'recommendation_service'
require_relative 'providers'
require_relative 'analytics'
require_relative 'symbol_index'
require_relative 'watchlist_store'
require_relative 'alerts_store'
require_relative 'portfolio_store'
require_relative 'trades_store'
require_relative 'wash_sale'
require_relative 'profile_store'
require_relative 'tax_harvester'
require_relative 'fidelity_importer'
require_relative 'import_snapshot_store'
require_relative 'portfolio_history'
require_relative 'retirement_projection'
require_relative 'portfolio_diff'
require_relative 'refresh_universe'
require_relative 'refresh_tracker'
require_relative 'health_registry'
require_relative 'correlation_store'

class TMoneyTerminal < Sinatra::Base
  set :views, File.expand_path('../../views', __FILE__)
  set :public_folder, File.expand_path('../../public', __FILE__)

  before do
    fresh_entries = MarketDataService.cache_summary.reject { |e| e[:is_stale] || e[:cached_at].nil? }
    @cache_updated_at = fresh_entries.map { |e| e[:cached_at] }.max
  end

  get '/' do
    redirect '/dashboard'
  end

  get '/dashboard' do
    @data    = MarketDataService.summary
    @signals = RecommendationService.signals
    @macro   = safe_fetch { Providers::FredService.macro_snapshot } || {}
    @indices = safe_fetch do
      %i[sp500 nasdaq dow nikkei hang_seng dax ftse cac].each_with_object({}) do |key, acc|
        row = Providers::StooqService.index(key)
        acc[key] = row if row
      end
    end || {}

    # Watchlist — server-side persisted; rendered as a quote table.
    @watchlist_symbols = WatchlistStore.read
    @watchlist_quotes  = @watchlist_symbols.map do |sym|
      q = safe_fetch { MarketDataService.quote(sym) }
      { symbol: sym, quote: q }
    end

    # Upcoming earnings (next 7 days) — cross-reference the FMP calendar
    # against every symbol the app knows about (REGIONS + curated + watchlist).
    @upcoming_earnings = safe_fetch { upcoming_earnings_for_universe } || []

    # Provider degradation: surface a banner when any upstream is failing
    # majority of recent calls. Hidden until at least 5 observations exist
    # so the banner doesn't fire on cold start.
    @degraded_providers = HealthRegistry.degraded

    erb :dashboard
  end

  get '/us' do
    @data = MarketDataService.region(:us)
    erb :us_markets
  end

  get '/japan' do
    @data = MarketDataService.region(:japan)
    erb :japan_markets
  end

  get '/europe' do
    @data = MarketDataService.region(:europe)
    erb :europe_markets
  end

  get '/recommendations' do
    redirect '/dashboard', 301
  end
  
  # Refresh routes for manual cache busting
  post '/refresh/dashboard' do
    # Refresh all symbols across all regions
    symbols = MarketDataService::REGIONS.values.flatten.uniq
    symbols.each { |s| MarketDataService.bust_cache_for_symbol!(s) }
    redirect '/dashboard', 302
  end
  
  post '/refresh/region/:name' do
    # Refresh symbols for specific region
    region_name = params['name'].downcase
    halt 404, 'Region not found' unless VALID_REGION_NAMES.include?(region_name)
    
    symbols = MarketDataService::REGIONS[region_name.to_sym]
    symbols.each { |s| MarketDataService.bust_cache_for_symbol!(s) }
    redirect "/region/#{region_name}", 302
  end
  
  post '/refresh/analysis/:symbol' do
    # Refresh single symbol
    symbol = params['symbol'].upcase
    halt 404, 'Symbol not found' unless SymbolIndex.known?(symbol)

    MarketDataService.bust_cache_for_symbol!(symbol)
    redirect "/analysis/#{symbol}", 302
  end

  # Legacy module wrapper — kept so external callers (and existing tests) that
  # reference `TMoneyTerminal::VALID_SYMBOLS.include?(sym)` keep working. Now
  # delegates to `SymbolIndex.known?` so runtime-discovered tickers are honored.
  VALID_SYMBOLS = Module.new do
    def self.include?(symbol); SymbolIndex.known?(symbol); end
    def self.to_a;             SymbolIndex.symbols;        end
  end
  VALID_REGION_NAMES = MarketDataService::REGIONS.keys.map(&:to_s).freeze

  get '/region/:name' do
    region_name = params['name'].downcase
    halt 404, 'Region not found' unless VALID_REGION_NAMES.include?(region_name)
    @region_label = MarketDataService::REGION_LABEL[region_name.to_sym]
    @data = MarketDataService.region(region_name.to_sym)
    erb :region
  end

  get '/analysis/:symbol' do
    symbol = params['symbol'].upcase
    halt 404, 'Symbol not found' unless SymbolIndex.known?(symbol)

    # ?refresh=1 clears live cache entries for this symbol and redirects clean.
    # Persistent fallback is preserved so historical charts don't go blank under provider throttling.
    if params['refresh'] == '1'
      MarketDataService.refresh_symbol_live_cache!(symbol)
      redirect "/analysis/#{symbol}", 302
    end

    @symbol      = symbol
    @quote       = MarketDataService.quote(symbol)
    @analyst     = MarketDataService.analyst_recommendations(symbol)
    @profile     = MarketDataService.company_profile(symbol)
    detail       = RecommendationService.signal_detail(symbol)
    @signal      = detail[:signal]
    @signal_type = detail[:signal_type]
    @historical  = MarketDataService.historical(symbol, '1y')

    # Provider-sourced enrichment (all calls are cache-first and return nil on
    # missing keys / errors, so the page still renders if a provider is down).
    is_etf        = MarketDataService::SYMBOL_TYPES[symbol] == 'ETF'
    @news         = safe_fetch { Providers::NewsService.company_news(symbol, days: 7, limit: 8) }
    unless is_etf
      @key_metrics  = safe_fetch { Providers::FmpService.key_metrics(symbol, limit: 1)&.first }
      @ratios       = safe_fetch { Providers::FmpService.ratios(symbol, limit: 1)&.first }
      @dcf          = safe_fetch { Providers::FmpService.dcf(symbol) }
      @earnings     = safe_fetch { Providers::FmpService.next_earnings(symbol) }
    end

    # Analytics (pure Ruby, zero API calls) — use cached historicals.
    @analytics = safe_fetch { compute_analytics(symbol, @historical) } || {}

    # Holding (if any) — joined to live quote so the Position panel can show
    # market value and unrealized P&L without re-fetching. `find` returns the
    # aggregated open position across all lots; per-lot detail is in :lots.
    raw_position = PortfolioStore.find(symbol)
    @position    = raw_position ? valuate_position(raw_position) : nil

    # Determine if any data is stale (served from persistent fallback cache)
    stale_keys  = [symbol, "analyst:#{symbol}", "profile:#{symbol}", "candle:#{symbol}:1y"]
    stale_infos = stale_keys.map { |k| MarketDataService.cache_info_for(k) }.select { |i| i[:is_stale] }
    if stale_infos.any?
      oldest = stale_infos.map { |i| i[:cached_at] }.compact.min
      @stale_banner = oldest ? "Serving cached data from #{oldest.strftime('%B %d, %Y at %H:%M %Z')}. Live data is currently unavailable." \
                             : "Serving cached data. Live data is currently unavailable."
    end

    erb :analysis
  end

  get '/api/candle/:symbol/:period' do
    symbol = params['symbol'].upcase
    halt 404, { error: 'Symbol not found' }.to_json unless SymbolIndex.known?(symbol)

    valid_periods = %w[1d 1m 3m ytd 1y 5y]
    period = params['period']
    halt 400, { error: 'Invalid period' }.to_json unless valid_periods.include?(period)

    content_type :json
    bars = MarketDataService.historical(symbol, period) || []
    { bars: bars, indicators: compute_indicator_series(bars) }.to_json
  end

  get '/api/market/:region' do
    region = params['region'].to_sym
    content_type :json
    MarketDataService.region(region).to_json
  end

  get '/api/quote/alpha/:symbol' do
    content_type :json
    MarketDataService.quote(params['symbol']).to_json
  end

  get '/admin/cache' do
    @cache_entries = MarketDataService.cache_summary
    @refresh_all_status = RefreshTracker.current('all')
    @refreshed_symbol   = params['refreshed']
    @refresh_started    = params['refresh_started']
    @refresh_busy       = params['refresh_busy']
    erb :admin_cache
  end

  # Bust + refetch every cache for a single symbol (quote, analyst, profile,
  # historicals). Synchronous — call returns when fresh data is on disk.
  # Used by the per-row "Refresh" button on /admin/cache.
  post '/admin/refresh/symbol' do
    symbol = params['symbol'].to_s.strip.upcase
    halt 400, 'symbol required' if symbol.empty?

    MarketDataService.bust_cache_for_symbol!(symbol)
    safe_fetch { MarketDataService.quote(symbol) }
    safe_fetch { MarketDataService.analyst_recommendations(symbol) }
    safe_fetch { MarketDataService.company_profile(symbol) }
    safe_fetch { MarketDataService.historical(symbol, '1y') }

    redirect "/admin/cache?refreshed=#{URI.encode_www_form_component(symbol)}", 302
  end

  # Background refresh-all: iterate the universe and rebuild every cache
  # entry. Runs in a Thread because Polygon's 13s/call throttle means a
  # ~500-symbol portfolio takes 30+ minutes. The /admin/cache view polls
  # RefreshTracker.current('all') to render a progress banner.
  post '/admin/refresh/all' do
    if RefreshTracker.running?('all')
      redirect '/admin/cache?refresh_busy=1', 302
      return
    end

    symbols = RefreshUniverse.symbols
    RefreshTracker.start!('all', total: symbols.length)

    Thread.new do
      Thread.current.name = 'refresh-all' if Thread.current.respond_to?(:name=)
      Thread.current.report_on_exception = false if Thread.current.respond_to?(:report_on_exception=)
      symbols.each do |sym|
        begin
          MarketDataService.bust_cache_for_symbol!(sym)
          MarketDataService.quote(sym)
          MarketDataService.analyst_recommendations(sym)
          MarketDataService.company_profile(sym)
          MarketDataService.historical(sym, '1y')
        rescue StandardError => e
          RefreshTracker.record_error('all', sym, "#{e.class}: #{e.message}")
        ensure
          RefreshTracker.tick('all', last_symbol: sym)
        end
      end
      RefreshTracker.complete!('all', ok: true)
    rescue StandardError => e
      RefreshTracker.complete!('all', ok: false)
      warn "[refresh-all] thread aborted: #{e.class}: #{e.message}" unless ENV['RACK_ENV'] == 'test'
    end

    redirect '/admin/cache?refresh_started=all', 302
  end

  get '/api/admin/refresh/status.json' do
    content_type :json
    job = RefreshTracker.current('all')
    halt 404, { error: 'no refresh-all job' }.to_json unless job
    job.merge(
      started_at:   job[:started_at]&.iso8601,
      completed_at: job[:completed_at]&.iso8601
    ).to_json
  end

  get '/admin/health' do
    @health_rows = HealthRegistry.summary
    erb :admin_health
  end

  get '/api/admin/health.json' do
    content_type :json
    { providers: HealthRegistry.summary.map { |row|
        row.merge(
          last_ok_at:    row[:last_ok_at]&.iso8601,
          last_error_at: row[:last_error_at]&.iso8601
        )
      } }.to_json
  end

  # -------------------------------------------------------------------------
  # Search (§4.1)
  # -------------------------------------------------------------------------

  # Autocomplete feed for the top-nav search box. If `q` is provided, returns
  # ranked prefix/substring matches; otherwise returns the full universe so
  # the client can cache it locally for offline filtering.
  get '/api/symbols' do
    content_type :json
    q     = params['q'].to_s.strip
    limit = (params['limit'] || 10).to_i.clamp(1, 50)
    results = q.empty? ? SymbolIndex.to_a : SymbolIndex.search(q, limit: limit)

    # If the query looks like a ticker but matched nothing in the index, hint
    # to the client that it can try discovery (POST /api/symbols/discover).
    can_discover = !q.empty? && results.empty? && SymbolIndex.looks_like_ticker?(q)

    { results: results, total: SymbolIndex.to_a.length, can_discover: can_discover, query: q.upcase }.to_json
  end

  # Attempt to bring an unknown ticker into the index. Hits the live quote
  # waterfall once; if a real price comes back we persist the symbol to
  # data/symbols_extended.json so subsequent searches and /analysis/:symbol
  # resolve. Failures (unknown ticker, all providers down) return 404 so the
  # client can show a "couldn't find that ticker" message.
  post '/api/symbols/discover' do
    content_type :json
    body   = request_json
    symbol = (body['symbol'] || params['symbol']).to_s.strip.upcase

    halt 400, { error: 'symbol required' }.to_json if symbol.empty?
    halt 400, { error: "'#{symbol}' doesn't look like a ticker" }.to_json unless SymbolIndex.looks_like_ticker?(symbol)

    # Already known? Treat as a no-op success — UI can route straight to /analysis.
    if SymbolIndex.known?(symbol)
      return { symbol: symbol, name: symbol, region: 'Other', already_known: true }.to_json
    end

    quote = safe_fetch { MarketDataService.quote(symbol) } || {}
    price = (quote['05. price'] || quote[:price]).to_f
    halt 404, { error: "no quote available for '#{symbol}'" }.to_json if price <= 0

    # Best-effort name lookup. Don't fail discovery if profile is unavailable.
    profile = safe_fetch { MarketDataService.company_profile(symbol) } || {}
    name    = profile[:name].to_s.empty? ? symbol : profile[:name]
    region  = profile[:exchange].to_s.empty? ? 'Other' : profile[:exchange]

    entry = SymbolIndex.add_extension(symbol, name: name, region: region, source: 'discovery')
    entry.to_json
  end

  # -------------------------------------------------------------------------
  # Watchlist (§4.2)
  # -------------------------------------------------------------------------

  get '/api/watchlist' do
    content_type :json
    { symbols: WatchlistStore.read }.to_json
  end

  post '/api/watchlist' do
    content_type :json
    symbol = (params['symbol'] || request_json['symbol']).to_s.upcase
    halt 400, { error: 'symbol required' }.to_json if symbol.empty?
    halt 404, { error: 'Unknown symbol' }.to_json unless SymbolIndex.known?(symbol)
    { symbols: WatchlistStore.add(symbol) }.to_json
  end

  delete '/api/watchlist/:symbol' do
    content_type :json
    { symbols: WatchlistStore.remove(params['symbol']) }.to_json
  end

  # Form-POST fallback used by the dashboard watchlist row's ✕ button so the
  # remove action works even when JS is disabled / hasn't loaded yet.
  post '/watchlist/remove' do
    WatchlistStore.remove(params['symbol']) if params['symbol']
    redirect '/dashboard', 302
  end

  # -------------------------------------------------------------------------
  # Portfolio (lot-based)
  # -------------------------------------------------------------------------

  get '/portfolio' do
    @rows    = PortfolioStore.positions.map { |p| valuate_position(p) }
    @totals  = portfolio_totals(@rows)
    @latest_snapshot = ImportSnapshotStore.latest(source: 'fidelity')
    @snapshot_count  = ImportSnapshotStore.list(source: 'fidelity').length
    merge_broker_fields!(@rows, @latest_snapshot)
    annotate_portfolio_signals!(@rows, @totals)
    @realized_ytd          = TradesStore.realized_pl_ytd
    @realized_short_ytd    = TradesStore.realized_pl_short_term_ytd
    @realized_long_ytd     = TradesStore.realized_pl_long_term_ytd
    # Cache-only benchmark read — never fires providers on /portfolio render.
    # If the SPY 5y cache is empty, the panel is hidden until the next
    # scheduler run / explicit refresh / analysis-page visit warms it.
    @benchmark = safe_fetch do
      Analytics::Benchmark.compare(
        @rows,
        bars_for: ->(sym) { MarketDataService.historical_cached(sym, '5y') }
      )
    end
    @import_count     = params['imported_count']&.to_i
    @import_file_date = params['imported_file']
    @import_skipped   = params['imported_skipped']&.to_i
    @import_prefetch  = params['prefetch_started']&.to_i
    @latest_fidelity  = FidelityImporter.latest_file_in
    @backfill_pending = FidelityImporter.pending_backfill_count
    @backfill_count   = params['backfill_count']&.to_i
    @backfill_errors  = params['backfill_errors']&.to_i
    @history_series   = PortfolioHistory.time_series(source: 'fidelity')
    @history_per_sym  = PortfolioHistory.per_symbol_series(source: 'fidelity')
    # Retirement projection — uses live @totals if PortfolioStore has positions,
    # else falls back to the latest snapshot's total_value so users running
    # snapshot-only (no PortfolioStore lots) still see the section.
    current_value = @totals[:market_value].to_f
    if current_value <= 0 && @history_series.last
      current_value = @history_series.last[:total_value].to_f
    end
    @retirement = RetirementProjection.project(
      profile:       ProfileStore.read,
      current_value: current_value
    )
    @movers     = PortfolioHistory.movers(top_n: 5, source: 'fidelity')
    @allocation = PortfolioHistory.allocation_breakdown(source: 'fidelity')
    erb :portfolio
  end

  get '/api/portfolio' do
    content_type :json
    rows = PortfolioStore.positions.map { |p| valuate_position(p) }
    {
      positions:    rows,
      totals:       portfolio_totals(rows),
      realized_ytd: TradesStore.realized_pl_ytd
    }.to_json
  end

  # Buy a new lot. Always creates a NEW lot (no upsert / replace semantics).
  post '/api/portfolio/buy' do
    content_type :json
    body = request_json
    sym  = (body['symbol'] || params['symbol']).to_s.upcase
    halt 404, { error: 'Unknown symbol' }.to_json unless SymbolIndex.known?(sym)
    begin
      lot = PortfolioStore.add_lot(
        symbol:      sym,
        shares:      (body['shares']      || params['shares']),
        cost_basis:  (body['cost_basis']  || body['price']  || params['cost_basis'] || params['price']),
        acquired_at: (body['acquired_at'] || params['acquired_at']),
        notes:       (body['notes']       || params['notes'])
      )
      TradesStore.record_buy(
        symbol: lot[:symbol],
        shares: lot[:shares],
        price:  lot[:cost_basis],
        date:   lot[:acquired_at],
        notes:  lot[:notes],
        lot_id: lot[:id]
      )
      lot.to_json
    rescue ArgumentError => e
      halt 400, { error: e.message }.to_json
    end
  end

  # Sell shares of a held symbol via FIFO. Returns the realized-P&L breakdown.
  post '/api/portfolio/sell' do
    content_type :json
    body = request_json
    sym  = (body['symbol'] || params['symbol']).to_s.upcase
    halt 404, { error: 'Unknown symbol' }.to_json unless SymbolIndex.known?(sym)

    begin
      breakdown = PortfolioStore.close_shares_fifo(
        symbol:  sym,
        shares:  (body['shares']  || params['shares']),
        price:   (body['price']   || params['price']),
        sold_at: (body['sold_at'] || params['sold_at'])
      )
      flags = safe_fetch { WashSale.check(breakdown) } || []
      TradesStore.record_sell(breakdown,
                              notes: (body['notes'] || params['notes']),
                              wash_sale_flags: flags)
      breakdown.merge(wash_sale_flags: flags).to_json
    rescue ArgumentError => e
      halt 400, { error: e.message }.to_json
    end
  end

  # Dry-run a sell — same FIFO + tax classification + wash-sale check
  # logic, but doesn't mutate PortfolioStore or TradesStore. Used by the
  # sell preview UI so the user can see the breakdown (short-term loss,
  # wash-sale warning, etc.) before committing.
  post '/api/portfolio/sell/preview' do
    content_type :json
    body = request_json
    sym  = (body['symbol'] || params['symbol']).to_s.upcase
    halt 404, { error: 'Unknown symbol' }.to_json unless SymbolIndex.known?(sym)

    begin
      shares  = Float(body['shares']  || params['shares'])
      price   = Float(body['price']   || params['price'])
      sold_at = (body['sold_at'] || params['sold_at']).to_s
    rescue ArgumentError => e
      halt 400, { error: e.message }.to_json
    end

    # Snapshot in-memory state, do the close, capture the breakdown, then
    # restore. PortfolioStore writes to disk inside `synchronize`, so we
    # persist the snapshot to disk and restore it on the way out.
    state_before = File.exist?(PortfolioStore.path) ? File.read(PortfolioStore.path) : nil
    trades_before = File.exist?(TradesStore.path) ? File.read(TradesStore.path) : nil
    begin
      breakdown = PortfolioStore.close_shares_fifo(symbol: sym, shares: shares, price: price, sold_at: sold_at)
      flags     = safe_fetch { WashSale.check(breakdown) } || []
      breakdown.merge(wash_sale_flags: flags, preview: true).to_json
    rescue ArgumentError => e
      halt 400, { error: e.message }.to_json
    ensure
      # Restore stores so the preview is non-destructive.
      File.write(PortfolioStore.path, state_before) if state_before
      File.delete(PortfolioStore.path) if !state_before && File.exist?(PortfolioStore.path)
      File.write(TradesStore.path, trades_before)   if trades_before
      File.delete(TradesStore.path) if !trades_before && File.exist?(TradesStore.path)
    end
  end

  # Wipe all lots for a symbol without recording a trade — for typo correction.
  delete '/api/portfolio/:symbol' do
    content_type :json
    list = PortfolioStore.remove(params['symbol'])
    { lots: list }.to_json
  end

  # Remove a single lot by id (also for typo correction).
  delete '/api/lots/:id' do
    content_type :json
    list = PortfolioStore.remove_lot(params['id'])
    { lots: list }.to_json
  end

  # --- Snapshot drift / portfolio changes ---

  # Compares the latest two Fidelity snapshots and shows what changed:
  # positions added, sold, scaled up/down, plus value-delta totals.
  # Big-mover rows surface first; unchanged positions appear last for context.
  get '/portfolio/drift' do
    @snapshots = ImportSnapshotStore.list(source: 'fidelity')
    @diff = @snapshots.length >= 2 ? PortfolioDiff.compute_latest_pair(source: 'fidelity') : nil
    erb :drift
  end

  get '/api/portfolio/drift' do
    content_type :json
    diff = PortfolioDiff.compute_latest_pair(source: 'fidelity')
    halt 404, { error: 'need at least 2 snapshots to compute drift' }.to_json unless diff
    diff.to_json
  end

  # --- Tax-loss harvesting analysis ---

  # Sub-page under /portfolio. Identifies open lots with unrealised
  # losses, estimates tax savings using the user's profile rates,
  # surfaces wash-sale risk + ST→LT crossings + replacement security
  # suggestions, and recommends an action per candidate based on the
  # user's risk_tolerance + retirement timeline. Decision support, not
  # tax advice — view always renders the disclaimer.
  get '/portfolio/tax-harvest' do
    @profile  = ProfileStore.read
    @rows     = PortfolioStore.positions.map { |p| valuate_position(p) }
    @analysis = TaxHarvester.analyse(
      positions:          @rows,
      profile:            @profile,
      trades:             TradesStore.read,
      per_symbol_history: PortfolioHistory.per_symbol_series(source: 'fidelity')
    )
    @profile_configured = ProfileStore.configured?
    @years_to_retirement = ProfileStore.years_to_retirement
    erb :tax_harvest
  end

  get '/api/portfolio/tax-harvest' do
    content_type :json
    profile = ProfileStore.read
    rows    = PortfolioStore.positions.map { |p| valuate_position(p) }
    TaxHarvester.analyse(
      positions:          rows,
      profile:            profile,
      trades:             TradesStore.read,
      per_symbol_history: PortfolioHistory.per_symbol_series(source: 'fidelity')
    ).to_json
  end

  # Update the user profile (current_age / retirement_age / risk_tolerance
  # / tax rates / NIIT / state). Form fallback. JSON-API peer is
  # POST /api/profile.
  post '/profile' do
    begin
      ProfileStore.update(
        current_age:             params['current_age'],
        retirement_age:          params['retirement_age'],
        risk_tolerance:          params['risk_tolerance'],
        federal_ltcg_rate:       params['federal_ltcg_rate'],
        federal_ordinary_rate:   params['federal_ordinary_rate'],
        state_tax_rate:          params['state_tax_rate'],
        niit_applies:            params['niit_applies'],
        retirement_target_value: params['retirement_target_value']
      )
      redirect (params['return_to'] || '/portfolio/tax-harvest'), 302
    rescue ArgumentError => e
      redirect "/portfolio/tax-harvest?profile_error=#{URI.encode_www_form_component(e.message)}", 302
    end
  end

  post '/api/profile' do
    content_type :json
    body = request_json
    begin
      updated = ProfileStore.update(body)
      updated.to_json
    rescue ArgumentError => e
      halt 400, { error: e.message }.to_json
    end
  end

  # --- Fidelity broker import ---

  # One-click import of the newest CSV in data/porfolio/fidelity/. Replaces
  # PortfolioStore lots for every symbol the file contains (file is
  # authoritative), registers unknown tickers as SymbolIndex extensions, and
  # primes the quote cache with the file's Last Price so the page renders
  # fast even when live providers are throttled.
  # Snapshot every unsnapshotted Fidelity CSV without touching PortfolioStore
  # or quote/historical caches. Each CSV represents a past day's holdings,
  # not the current state — backfilling lets the value-over-time chart and
  # per-position sparklines on /portfolio actually have history to render.
  # See FidelityImporter.backfill_snapshots! for the policy.
  post '/portfolio/import/fidelity/backfill' do
    begin
      result = FidelityImporter.backfill_snapshots!
      qs = "backfill_count=#{result[:snapshotted].length}" \
           "&backfill_errors=#{result[:errors].length}"
      redirect "/portfolio?#{qs}", 302
    rescue StandardError => e
      warn "[fidelity backfill] #{e.class}: #{e.message}" unless ENV['RACK_ENV'] == 'test'
      redirect "/portfolio?imported_error=#{URI.encode_www_form_component(e.message)}", 302
    end
  end

  get '/api/portfolio/history' do
    content_type :json
    {
      time_series:    PortfolioHistory.time_series(source: 'fidelity'),
      per_symbol:     PortfolioHistory.per_symbol_series(source: 'fidelity'),
      generated_at:   Time.now.utc.iso8601
    }.to_json
  end

  post '/portfolio/import/fidelity' do
    begin
      summary = FidelityImporter.import!
      qs = "imported_count=#{summary[:imported]}" \
           "&imported_file=#{summary[:file_date]&.iso8601}" \
           "&imported_skipped=#{summary[:skipped].length}" \
           "&prefetch_started=#{summary[:prefetch_started] || 0}"
      redirect "/portfolio?#{qs}", 302
    rescue StandardError => e
      warn "[fidelity import] #{e.class}: #{e.message}" unless ENV['RACK_ENV'] == 'test'
      redirect "/portfolio?imported_error=#{URI.encode_www_form_component(e.message)}", 302
    end
  end

  get '/api/portfolio/import/fidelity/preview' do
    content_type :json
    path = FidelityImporter.latest_file_in
    halt 404, { error: 'no Fidelity CSV found' }.to_json unless path
    parsed = FidelityImporter.parse(path)
    {
      file_path: parsed[:file_path],
      file_date: parsed[:file_date]&.iso8601,
      positions_count: parsed[:positions].length,
      skipped_count:   parsed[:skipped].length,
      positions:       parsed[:positions]
    }.to_json
  end

  # --- Form-POST fallbacks (work without JS) ---

  post '/portfolio/buy' do
    if SymbolIndex.known?(params['symbol'].to_s.upcase)
      begin
        lot = PortfolioStore.add_lot(
          symbol:      params['symbol'],
          shares:      params['shares'],
          cost_basis:  params['cost_basis'] || params['price'],
          acquired_at: params['acquired_at'],
          notes:       params['notes']
        )
        TradesStore.record_buy(
          symbol: lot[:symbol], shares: lot[:shares], price: lot[:cost_basis],
          date: lot[:acquired_at], notes: lot[:notes], lot_id: lot[:id]
        )
      rescue ArgumentError
        # silent — page redirect lets the user see current state
      end
    end
    redirect (params['return_to'] || '/portfolio'), 302
  end

  post '/portfolio/sell' do
    if SymbolIndex.known?(params['symbol'].to_s.upcase)
      begin
        breakdown = PortfolioStore.close_shares_fifo(
          symbol:  params['symbol'],
          shares:  params['shares'],
          price:   params['price'],
          sold_at: params['sold_at']
        )
        flags = safe_fetch { WashSale.check(breakdown) } || []
        TradesStore.record_sell(breakdown, notes: params['notes'], wash_sale_flags: flags)
      rescue ArgumentError
        # silent
      end
    end
    redirect (params['return_to'] || '/portfolio'), 302
  end

  post '/portfolio/remove' do
    PortfolioStore.remove(params['symbol']) if params['symbol']
    redirect '/portfolio', 302
  end

  post '/lots/remove' do
    PortfolioStore.remove_lot(params['id']) if params['id']
    redirect (params['return_to'] || '/portfolio'), 302
  end

  # -------------------------------------------------------------------------
  # Trade history (§F)
  # -------------------------------------------------------------------------

  get '/trades' do
    @symbol = params['symbol'].to_s.upcase
    @symbol = nil if @symbol.empty? || !SymbolIndex.known?(@symbol)
    @trades = @symbol ? TradesStore.for_symbol(@symbol) : TradesStore.read
    @realized_ytd        = TradesStore.realized_pl_ytd
    @realized_total      = TradesStore.realized_pl_total
    @realized_short_ytd  = TradesStore.realized_pl_short_term_ytd
    @realized_long_ytd   = TradesStore.realized_pl_long_term_ytd
    erb :trades
  end

  get '/api/trades' do
    content_type :json
    sym = params['symbol']&.upcase
    list = sym && SymbolIndex.known?(sym) ? TradesStore.for_symbol(sym) : TradesStore.read
    {
      trades:         list,
      realized_ytd:   TradesStore.realized_pl_ytd,
      realized_total: TradesStore.realized_pl_total
    }.to_json
  end

  # -------------------------------------------------------------------------
  # Price alerts (§4.4)
  # -------------------------------------------------------------------------

  get '/api/alerts' do
    content_type :json
    sym = params['symbol']&.upcase
    list = AlertsStore.read
    list = list.select { |a| a[:symbol] == sym } if sym
    { alerts: list }.to_json
  end

  post '/api/alerts' do
    content_type :json
    body = request_json
    begin
      alert = AlertsStore.add(
        symbol:    body['symbol']    || params['symbol'],
        condition: body['condition'] || params['condition'],
        threshold: body['threshold'] || params['threshold']
      )
      alert.to_json
    rescue ArgumentError => e
      halt 400, { error: e.message }.to_json
    end
  end

  delete '/api/alerts/:id' do
    content_type :json
    { alerts: AlertsStore.remove(params['id']) }.to_json
  end

  # -------------------------------------------------------------------------
  # CSV / JSON export (§4.5)
  # -------------------------------------------------------------------------

  get '/api/export/:symbol/:period.csv' do
    symbol = params['symbol'].upcase
    halt 404, 'Symbol not found' unless SymbolIndex.known?(symbol)

    period = params['period']
    halt 400, 'Invalid period' unless %w[1d 1m 3m ytd 1y 5y].include?(period)

    bars       = MarketDataService.historical(symbol, period) || []
    indicators = compute_indicator_series(bars)

    content_type 'text/csv'
    attachment  "#{symbol}_#{period}.csv"

    CSV.generate do |csv|
      csv << %w[date open high low close adj_close volume sma20 sma50 sma200
                bb_upper bb_middle bb_lower rsi macd macd_signal macd_histogram]
      bars.each_with_index do |b, i|
        csv << [
          b[:date]      || b['date'],
          b[:open]      || b['open'],
          b[:high]      || b['high'],
          b[:low]       || b['low'],
          b[:close]     || b['close'],
          b[:adj_close] || b['adj_close'],
          b[:volume]    || b['volume'],
          indicators[:sma20]&.dig(i),
          indicators[:sma50]&.dig(i),
          indicators[:sma200]&.dig(i),
          indicators[:bb_upper]&.dig(i),
          indicators[:bb_middle]&.dig(i),
          indicators[:bb_lower]&.dig(i),
          indicators[:rsi]&.dig(i),
          indicators[:macd]&.dig(i),
          indicators[:macd_signal]&.dig(i),
          indicators[:macd_histogram]&.dig(i)
        ]
      end
    end
  end

  # -------------------------------------------------------------------------
  # Compare mode (§4.6)
  # -------------------------------------------------------------------------

  get '/compare' do
    requested = (params['symbols'] || '').split(',').map { |s| s.strip.upcase }.reject(&:empty?)
    @symbols  = requested.select { |s| SymbolIndex.known?(s) }.first(6)
    @period   = %w[1m 3m ytd 1y 5y].include?(params['period']) ? params['period'] : '1y'
    erb :compare
  end

  # Returns rebased-to-100 series for /compare. Each series is an array of
  # { date:, value: } where value = 100 * close / first_close.
  get '/api/compare' do
    content_type :json
    symbols = (params['symbols'] || '').split(',').map { |s| s.strip.upcase }
                .select { |s| SymbolIndex.known?(s) }.first(6)
    period  = %w[1m 3m ytd 1y 5y].include?(params['period']) ? params['period'] : '1y'

    series = symbols.map do |sym|
      bars = safe_fetch { MarketDataService.historical(sym, period) } || []
      points = rebase_to_100(bars)
      { symbol: sym, points: points }
    end
    { period: period, series: series }.to_json
  end

  # -------------------------------------------------------------------------
  # Correlation heatmap
  # -------------------------------------------------------------------------

  CORRELATION_VALID_PERIODS = %w[1m 3m ytd 1y 5y].freeze
  CORRELATION_MAX_SYMBOLS   = 12

  get '/correlations' do
    requested = parse_correlation_symbols(params['symbols'])
    @symbols  = requested.first(CORRELATION_MAX_SYMBOLS)
    @period   = CORRELATION_VALID_PERIODS.include?(params['period']) ? params['period'] : '1y'
    @payload  = @symbols.length >= 2 ? CorrelationStore.matrix_for(@symbols, period: @period) : nil
    erb :correlations
  end

  get '/api/correlations' do
    content_type :json
    symbols = parse_correlation_symbols(params['symbols'])
    halt 400, { error: "supply 2..#{CORRELATION_MAX_SYMBOLS} symbols" }.to_json if symbols.length < 2
    halt 400, { error: "max #{CORRELATION_MAX_SYMBOLS} symbols" }.to_json if symbols.length > CORRELATION_MAX_SYMBOLS
    period = CORRELATION_VALID_PERIODS.include?(params['period']) ? params['period'] : '1y'
    CorrelationStore.matrix_for(symbols, period: period).to_json
  end

  helpers do
    # Cache-busting asset mtime used in layout.erb for /style.css and /app.js.
    def asset_mtime(relative_path)
      path = File.join(settings.root, '..', relative_path)
      File.exist?(path) ? File.mtime(path).to_i : 0
    end

    # Wrap provider calls so any failure (missing key, network error, parse
    # error) yields nil instead of 500ing the page.
    def safe_fetch
      yield
    rescue StandardError => e
      warn "[safe_fetch] #{e.class}: #{e.message}" unless ENV['RACK_ENV'] == 'test'
      nil
    end

    # Format a large dollar amount as $X.XXB / $X.XXT / $X.XM.
    def format_money(value)
      return 'N/A' if value.nil?
      n = value.to_f
      return '$0' if n.zero?

      abs = n.abs
      sign = n.negative? ? '-' : ''
      if abs >= 1e12 then "#{sign}$#{format('%.2f', abs / 1e12)}T"
      elsif abs >= 1e9  then "#{sign}$#{format('%.2f', abs / 1e9)}B"
      elsif abs >= 1e6  then "#{sign}$#{format('%.2f', abs / 1e6)}M"
      elsif abs >= 1e3  then "#{sign}$#{format('%.2f', abs / 1e3)}K"
      else                   "#{sign}$#{format('%.2f', abs)}"
      end
    end

    # Format a ratio/multiplier (e.g. P/E) to 2 decimals, or em-dash if nil.
    def format_ratio(value)
      value.nil? ? '—' : format('%.2f', value.to_f)
    end

    # Format a decimal fraction as percent, e.g. 0.214 → "21.4%".
    def format_percent(value, digits: 2)
      value.nil? ? '—' : "#{format("%.#{digits}f", value.to_f * 100)}%"
    end

    # Classify the current price's position within its Bollinger Bands.
    def bollinger_position(price, upper, middle, lower)
      return '—' if [price, upper, middle, lower].any?(&:nil?)
      return 'Above upper band' if price > upper
      return 'Below lower band' if price < lower
      price > middle ? 'Upper half' : 'Lower half'
    end

    # Short text label for an RSI reading.
    def rsi_label(rsi)
      return '—' if rsi.nil?
      return 'Overbought' if rsi > 70
      return 'Oversold'   if rsi < 30
      'Neutral'
    end

    # Diverging red(-1) → white(0) → green(+1) colormap for the correlation
    # heatmap cells. Pure CSS rgb() so the page remains print/screenshot clean.
    def correlation_color(v)
      return '#f2f2f7' if v.nil? # neutral grey for missing
      t = [-1.0, [1.0, v.to_f].min].max
      intensity = t.abs
      if t >= 0
        r = (255 + (52  - 255) * intensity).round
        g = (255 + (199 - 255) * intensity).round
        b = (255 + (89  - 255) * intensity).round
      else
        r = 255 # 255 + (255 - 255) * intensity
        g = (255 + (59  - 255) * intensity).round
        b = (255 + (48  - 255) * intensity).round
      end
      "rgb(#{r}, #{g}, #{b})"
    end

    # Pick a contrasting text color so labels are readable against `bg_color`.
    # Uses the YIQ luminance heuristic. Inputs are the 'rgb(r, g, b)' strings
    # produced by `correlation_color`.
    def correlation_text_color(bg_color)
      m = bg_color.match(/rgb\((\d+),\s*(\d+),\s*(\d+)\)/)
      return '#1d1d1f' unless m
      r, g, b = m[1].to_i, m[2].to_i, m[3].to_i
      yiq = (r * 299 + g * 587 + b * 114) / 1000.0
      yiq >= 160 ? '#1d1d1f' : '#ffffff'
    end
  end

  # --- Indicator series for the chart API --------------------------------

  # Produces parallel arrays (same length as bars) of SMA 20/50/200, Bollinger
  # Bands (20, 2σ), RSI(14), and MACD(12/26/9). Used by /api/candle so the
  # TradingView chart can render overlays without computing anything client-side.
  def compute_indicator_series(bars)
    return empty_indicator_series if !bars.is_a?(Array) || bars.length < 2

    closes = bars.map { |b| (b[:close] || b['close']).to_f }
    ind    = Analytics::Indicators

    macd   = ind.macd(closes)
    bb     = ind.bollinger(closes, period: 20, stddev: 2)

    {
      sma20:          ind.sma(closes, 20),
      sma50:          ind.sma(closes, 50),
      sma200:         ind.sma(closes, 200),
      bb_upper:       bb[:upper],
      bb_middle:      bb[:middle],
      bb_lower:       bb[:lower],
      rsi:            ind.rsi(closes, period: 14),
      macd:           macd[:macd],
      macd_signal:    macd[:signal],
      macd_histogram: macd[:histogram]
    }
  end

  def empty_indicator_series
    %i[sma20 sma50 sma200 bb_upper bb_middle bb_lower rsi macd macd_signal macd_histogram]
      .each_with_object({}) { |k, acc| acc[k] = [] }
  end

  # --- Analytics orchestration --------------------------------------------

  # Compute the full analytics bundle for a symbol from a cached historical
  # series (expected shape: [{date:, close:}]). All three sub-modules are
  # pure-Ruby, so this adds no API calls and is safe to call per request.
  def compute_analytics(symbol, historical)
    return {} unless historical.is_a?(Array) && historical.length >= 2

    # Indicators use raw close (chart-correct).
    closes = historical.map { |p| (p[:close] || p['close']).to_f }
    latest_close = closes.last

    # Risk metrics prefer dividend-adjusted close when available — Sharpe and
    # Sortino on raw close are wrong for dividend payers. Falls back to raw
    # close for providers that don't return adj_close (Finnhub, AV weekly).
    has_adj      = historical.any? { |p| p[:adj_close] || p['adj_close'] }
    risk_closes  = Analytics::Risk.closes_from(historical, total_return: has_adj)

    # --- Technical indicators --------------------------------------------
    sma50   = Analytics::Indicators.latest(Analytics::Indicators.sma(closes, 50))
    sma200  = Analytics::Indicators.latest(Analytics::Indicators.sma(closes, 200))
    rsi14   = Analytics::Indicators.latest(Analytics::Indicators.rsi(closes, period: 14))
    macd    = Analytics::Indicators.macd(closes)
    macd_l  = Analytics::Indicators.latest(macd[:macd])
    macd_s  = Analytics::Indicators.latest(macd[:signal])
    macd_h  = Analytics::Indicators.latest(macd[:histogram])
    bb      = Analytics::Indicators.bollinger(closes, period: 20, stddev: 2)
    bb_up   = Analytics::Indicators.latest(bb[:upper])
    bb_md   = Analytics::Indicators.latest(bb[:middle])
    bb_lo   = Analytics::Indicators.latest(bb[:lower])

    indicators = {
      latest_close: latest_close,
      sma50:   sma50,
      sma200:  sma200,
      rsi14:   rsi14,
      macd:    macd_l,
      macd_signal:    macd_s,
      macd_histogram: macd_h,
      bb_upper:  bb_up,
      bb_middle: bb_md,
      bb_lower:  bb_lo
    }

    # --- Risk & performance ----------------------------------------------
    rf = safe_fetch { Providers::FredService.risk_free_rate(term: :treasury_3mo) } || 0.0

    risk = {
      annualized_return:     Analytics::Risk.annualized_return(risk_closes),
      annualized_volatility: Analytics::Risk.annualized_volatility(risk_closes),
      sharpe:                Analytics::Risk.sharpe(risk_closes, risk_free_rate: rf),
      sortino:               Analytics::Risk.sortino(risk_closes, risk_free_rate: rf),
      max_drawdown:          Analytics::Risk.max_drawdown(risk_closes),
      var_historical_95:     Analytics::Risk.var_historical(risk_closes, confidence: 0.95),
      var_parametric_95:     Analytics::Risk.var_parametric(risk_closes, confidence: 0.95),
      risk_free_rate:        rf,
      beta_vs_spy:           compute_beta_vs_spy(symbol, historical),
      total_return:          has_adj
    }

    # --- Black-Scholes illustration (ATM, 30 days, realised vol) ---------
    hist_vol = Analytics::BlackScholes.historical_volatility(closes) || 0.0
    t_years  = 30.0 / 365.0
    bs = {}
    if latest_close && latest_close > 0 && hist_vol > 0
      call_px = Analytics::BlackScholes.price(:call, s: latest_close, k: latest_close,
                                              t: t_years, r: rf, sigma: hist_vol)
      put_px  = Analytics::BlackScholes.price(:put,  s: latest_close, k: latest_close,
                                              t: t_years, r: rf, sigma: hist_vol)
      greeks_call = Analytics::BlackScholes.greeks(:call, s: latest_close, k: latest_close,
                                                   t: t_years, r: rf, sigma: hist_vol)
      bs = {
        strike:           latest_close,
        expiry_days:      30,
        historical_vol:   hist_vol,
        risk_free_rate:   rf,
        call_price:       call_px,
        put_price:        put_px,
        greeks:           greeks_call
      }
    end

    { indicators: indicators, risk: risk, bs: bs }
  end

  # Parse a JSON request body into a Hash. Returns {} for empty/invalid bodies
  # so route handlers can merge with params transparently.
  def request_json
    @request_json ||= begin
      body = request.body.read
      request.body.rewind
      body.empty? ? {} : (JSON.parse(body) rescue {})
    end
  end

  # Comma-split, uppercase, dedupe, drop unknowns. Shared by `/correlations`
  # and `/api/correlations`. Empty input yields [].
  def parse_correlation_symbols(raw)
    (raw || '').split(',').map { |s| s.strip.upcase }
                .reject(&:empty?)
                .uniq
                .select { |s| SymbolIndex.known?(s) }
  end

  # Rebase a bars array ([{date:, close:}, ...]) to 100 on the first close.
  # Used by /api/compare so multiple symbols render on a shared scale.
  def rebase_to_100(bars)
    return [] unless bars.is_a?(Array) && !bars.empty?
    first = (bars.first[:close] || bars.first['close']).to_f
    return [] if first == 0
    bars.map do |b|
      date  = b[:date]  || b['date']
      close = (b[:close] || b['close']).to_f
      { date: date, value: (100.0 * close / first).round(4) }
    end
  end

  # Valuate an aggregated position (from PortfolioStore.positions) against
  # the cached quote. Adds derived fields: current_price, cost_value,
  # market_value, unrealized_pl ($), unrealized_pl_pct, day_change.
  # Missing quotes still return the entry with current_price: nil.
  #
  # Uses the strictly cache-only quote read (`quote_cached`) — `/portfolio`
  # and `/analysis/:symbol` rendering must NEVER fire a provider call. The
  # broker import is the canonical refresh event; page views just display
  # what was cached at the last update.
  def valuate_position(p)
    sym   = p[:symbol]
    quote = safe_fetch { MarketDataService.quote_cached(sym) } || {}
    price = (quote['05. price'] || quote[:price]).to_f

    cost_value      = (p[:shares].to_f * p[:cost_basis].to_f).round(2)
    market_value    = price > 0 ? (p[:shares].to_f * price).round(2) : nil
    unrealized_pl   = market_value ? (market_value - cost_value).round(2) : nil
    unrealized_pct  = (market_value && cost_value > 0) ? ((market_value - cost_value) / cost_value) : nil
    day_change_str  = quote['10. change percent'] || quote[:change]

    p.merge(
      current_price:     price > 0 ? price.round(4) : nil,
      cost_value:        cost_value,
      market_value:      market_value,
      unrealized_pl:     unrealized_pl,
      unrealized_pl_pct: unrealized_pct,
      day_change:        day_change_str
    )
  end

  # Merge broker-supplied fields from the most recent import snapshot into
  # each row. Broker fields use the `broker_` prefix so they don't collide
  # with our locally-computed valuations. Mutates rows in place.
  def merge_broker_fields!(rows, snapshot)
    return rows unless snapshot
    by_symbol = (snapshot['positions'] || []).each_with_object({}) do |p, acc|
      sym = p['symbol']&.upcase
      acc[sym] = p if sym
    end
    return rows if by_symbol.empty?

    rows.each do |row|
      bp = by_symbol[row[:symbol]]
      next unless bp
      row[:broker_pct_account]  = bp['pct_account']
      row[:broker_total_pl]     = bp['total_pl']
      row[:broker_day_change]   = bp['day_change']
      row[:broker_day_change_pct] = bp['day_change_pct']
      row[:broker_description]  = bp['description']
      row[:broker_accounts]     = bp['accounts']
    end
    rows
  end

  # Annotate each row with `:recommendation` (BUY/HOLD/SELL), `:notes` (array
  # of short observations: concentration risk, RSI extremes, trend vs SMA200),
  # and `:cost_basis_signal` (`:profit`/`:loss` vs broker basis). Mutates rows
  # in place. Best-effort — falls back silently if analytics aren't available.
  def annotate_portfolio_signals!(rows, totals)
    rows.each do |row|
      sym = row[:symbol]

      # Cached-only signal: /portfolio renders for every page view. We don't
      # want to fan out N Finnhub calls for analyst recs on each render —
      # the import + scheduler are the network events, the page is read-only.
      row[:recommendation] = safe_fetch { RecommendationService.signal_for(sym, cached_only: true) } || 'HOLD'

      notes = []
      pct_of_value = (totals[:market_value].to_f.positive? && row[:market_value]) \
                     ? (row[:market_value] / totals[:market_value]) : 0
      row[:weight] ||= pct_of_value
      notes << "Concentration #{format_percent(pct_of_value, digits: 1)} of portfolio" if pct_of_value > 0.20

      # Pull cached historicals if available — zero API cost, skip if cold.
      bars = safe_fetch { MarketDataService.send(:read_live_cache, "candle:#{sym}:1y") }
      if bars.is_a?(Array) && bars.length >= 50
        closes = bars.map { |b| (b[:close] || b['close']).to_f }
        rsi    = Analytics::Indicators.latest(Analytics::Indicators.rsi(closes, period: 14))
        sma200 = Analytics::Indicators.latest(Analytics::Indicators.sma(closes, 200))
        last   = closes.last

        if rsi
          notes << "RSI #{rsi.round} — overbought" if rsi > 70
          notes << "RSI #{rsi.round} — oversold"   if rsi < 30
        end
        if sma200 && last
          notes << 'Below SMA 200 — downtrend' if last < sma200 * 0.98
          notes << 'Above SMA 200 — uptrend'   if last > sma200 * 1.02
        end
      end

      # Broker-side context (only when we have a snapshot row for this symbol)
      if row[:broker_accounts] && row[:broker_accounts].any?
        notes << "Held in #{row[:broker_accounts].join(' + ')}"
      end
      if row[:broker_pct_account] && row[:broker_pct_account].abs > 20.0
        # Note: broker_pct_account is a percent (e.g. 39.80), not a decimal.
        notes << "Broker concentration #{row[:broker_pct_account].round(1)}%"
      end

      row[:notes_extra] = notes.uniq
    end
    rows
  end

  # Sum across valuated rows. Rows missing market_value (provider failed) are
  # excluded from the value totals but still counted in cost_value so the user
  # sees that something is missing rather than a silently understated total.
  def portfolio_totals(rows)
    cost_value   = rows.sum { |r| r[:cost_value].to_f }
    market_value = rows.sum { |r| r[:market_value].to_f }
    pl           = market_value - cost_value
    pl_pct       = cost_value > 0 ? pl / cost_value : nil

    # Per-row weight as a percentage of total market value (nil when total is 0).
    rows.each do |r|
      r[:weight] = (market_value > 0 && r[:market_value]) ? (r[:market_value] / market_value) : nil
    end

    {
      cost_value:        cost_value.round(2),
      market_value:      market_value.round(2),
      unrealized_pl:     pl.round(2),
      unrealized_pl_pct: pl_pct,
      positions_count:   rows.length
    }
  end

  # Combine all known symbols (REGIONS + curated + watchlist) against the FMP
  # earnings calendar and return the next ≤7 rows sorted by date.
  def upcoming_earnings_for_universe(days_ahead: 7, limit: 10)
    calendar = Providers::FmpService.earnings_calendar(days_ahead: days_ahead)
    return [] unless calendar.is_a?(Array) && !calendar.empty?

    universe = (SymbolIndex.symbols + WatchlistStore.read).map(&:upcase).uniq.to_set
    today    = Date.today
    cutoff   = today + days_ahead

    calendar.filter_map do |row|
      sym = row['symbol']&.upcase
      next unless sym && universe.include?(sym)
      date = row['date'] && (Date.parse(row['date']) rescue nil)
      next unless date && date >= today && date <= cutoff
      {
        symbol: sym,
        date:   date,
        eps_estimate: row['epsEstimated'],
        revenue_estimate: row['revenueEstimated'],
        time:   row['time']
      }
    end.sort_by { |r| r[:date] }.first(limit)
  end

  # Returns the beta of `symbol` vs SPY, or nil if SPY is the symbol itself
  # or historical data is unavailable / too short.
  def compute_beta_vs_spy(symbol, historical)
    return nil if symbol == 'SPY'

    spy = safe_fetch { MarketDataService.historical('SPY', '1y') }
    return nil if spy.nil? || spy.empty?

    # Use adj_close when both series carry it — beta on total returns is the
    # correct interpretation for dividend-paying assets.
    field = (historical.any? { |p| p[:adj_close] || p['adj_close'] } &&
             spy.any?        { |p| p[:adj_close] || p['adj_close'] }) ? :adj_close : :close
    asset_closes, bench_closes = Analytics::Risk.align_on_dates(historical, spy, field: field)
    return nil if asset_closes.length < 2
    Analytics::Risk.beta(asset_closes, bench_closes)
  end
end

if $PROGRAM_NAME == __FILE__
  TMoneyTerminal.run!
end
