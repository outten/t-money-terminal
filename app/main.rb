require 'sinatra'
require 'dotenv'
Dotenv.load(File.expand_path('../../.credentials', __FILE__))
require_relative 'market_data_service'
require_relative 'recommendation_service'
require_relative 'providers'

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
  end
end

if $PROGRAM_NAME == __FILE__
  TMoneyTerminal.run!
end
