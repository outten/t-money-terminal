require 'sinatra'
require 'dotenv'
Dotenv.load(File.expand_path('../../.credentials', __FILE__))
require_relative 'market_data_service'
require_relative 'recommendation_service'

class TMoneyTerminal < Sinatra::Base
  set :views, File.expand_path('../../views', __FILE__)
  set :public_folder, File.expand_path('../../public', __FILE__)

  get '/' do
    redirect '/dashboard'
  end

  get '/dashboard' do
    @data    = MarketDataService.summary
    @signals = RecommendationService.signals
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

  VALID_SYMBOLS = (MarketDataService::REGIONS.values.flatten).freeze

  get '/analysis/:symbol' do
    symbol = params['symbol'].upcase
    halt 404, 'Symbol not found' unless VALID_SYMBOLS.include?(symbol)

    # ?refresh=1 busts all cache entries for this symbol then redirects clean
    if params['refresh'] == '1'
      MarketDataService.bust_cache_for_symbol!(symbol)
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
end

if $PROGRAM_NAME == __FILE__
  TMoneyTerminal.run!
end
