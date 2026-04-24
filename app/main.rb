require 'sinatra'
require 'dotenv'
Dotenv.load(File.expand_path('../../.credentials', __FILE__))
require_relative 'market_data_service'
require_relative 'recommendation_service'
require_relative 'providers'
require_relative 'analytics'

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
    halt 404, 'Symbol not found' unless VALID_SYMBOLS.include?(symbol)
    
    MarketDataService.bust_cache_for_symbol!(symbol)
    redirect "/analysis/#{symbol}", 302
  end

  VALID_SYMBOLS      = (MarketDataService::REGIONS.values.flatten).freeze
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
    halt 404, 'Symbol not found' unless VALID_SYMBOLS.include?(symbol)

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
    halt 404, { error: 'Symbol not found' }.to_json unless VALID_SYMBOLS.include?(symbol)

    valid_periods = %w[1d 1m 3m ytd 1y 5y]
    period = params['period']
    halt 400, { error: 'Invalid period' }.to_json unless valid_periods.include?(period)

    content_type :json
    data = MarketDataService.historical(symbol, period)
    data ? data.to_json : [].to_json
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
    erb :admin_cache
  end

  helpers do
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
  end

  # --- Analytics orchestration --------------------------------------------

  # Compute the full analytics bundle for a symbol from a cached historical
  # series (expected shape: [{date:, close:}]). All three sub-modules are
  # pure-Ruby, so this adds no API calls and is safe to call per request.
  def compute_analytics(symbol, historical)
    return {} unless historical.is_a?(Array) && historical.length >= 2

    closes = historical.map { |p| (p[:close] || p['close']).to_f }
    latest_close = closes.last

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
      annualized_return:     Analytics::Risk.annualized_return(closes),
      annualized_volatility: Analytics::Risk.annualized_volatility(closes),
      sharpe:                Analytics::Risk.sharpe(closes, risk_free_rate: rf),
      sortino:               Analytics::Risk.sortino(closes, risk_free_rate: rf),
      max_drawdown:          Analytics::Risk.max_drawdown(closes),
      var_historical_95:     Analytics::Risk.var_historical(closes, confidence: 0.95),
      var_parametric_95:     Analytics::Risk.var_parametric(closes, confidence: 0.95),
      risk_free_rate:        rf,
      beta_vs_spy:           compute_beta_vs_spy(symbol, historical)
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

  # Returns the beta of `symbol` vs SPY, or nil if SPY is the symbol itself
  # or historical data is unavailable / too short.
  def compute_beta_vs_spy(symbol, historical)
    return nil if symbol == 'SPY'

    spy = safe_fetch { MarketDataService.historical('SPY', '1y') }
    return nil if spy.nil? || spy.empty?

    asset_closes, bench_closes = Analytics::Risk.align_on_dates(historical, spy)
    return nil if asset_closes.length < 2
    Analytics::Risk.beta(asset_closes, bench_closes)
  end
end

if $PROGRAM_NAME == __FILE__
  TMoneyTerminal.run!
end
