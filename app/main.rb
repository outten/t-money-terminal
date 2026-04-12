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
    @data = MarketDataService.summary
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
    @recommendations = RecommendationService.signals
    erb :recommendations
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
