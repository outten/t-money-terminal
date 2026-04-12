require 'dotenv'
Dotenv.load(
  File.expand_path('../../.env', __FILE__),
  File.expand_path('../../.credentials', __FILE__)
)
require 'net/http'
require 'json'
require 'time'

class MarketDataService
  CACHE_TTL = 86400 # 24 hours

  REGIONS = {
    us:     %w[SPY AAPL MSFT],
    japan:  %w[EWJ],
    europe: %w[VGK]
  }.freeze

  REGION_LABEL = { us: 'US', japan: 'Japan', europe: 'Europe' }.freeze

  MOCK_PRICES = {
    'SPY'  => { price: '520.00', change: '+1.2%', volume: '82000000' },
    'AAPL' => { price: '185.50', change: '-0.5%', volume: '55000000' },
    'MSFT' => { price: '415.75', change: '+0.8%', volume: '22000000' },
    'EWJ'  => { price: '72.10',  change: '+0.3%', volume: '4500000' },
    'VGK'  => { price: '69.40',  change: '+0.6%', volume: '2100000' }
  }.freeze

  @cache = {}
  @cache_timestamp = nil

  class << self
    def cache_fresh?
      @cache_timestamp && (Time.now - @cache_timestamp) < CACHE_TTL
    end

    def bust_cache!
      @cache = {}
      @cache_timestamp = nil
    end

    def quote(symbol)
      fetch_quote(symbol)
    end

    def region(name)
      symbols = REGIONS[name] || []
      quotes = symbols.map { |s| enrich_quote(s, REGION_LABEL[name]) }
      stale = !cache_fresh?
      { quotes: quotes, stale: stale, updated_at: @cache_timestamp&.iso8601 || 'N/A' }
    end

    def summary
      all_quotes = REGIONS.flat_map do |name, symbols|
        symbols.map { |s| enrich_quote(s, REGION_LABEL[name]) }
      end
      { quotes: all_quotes }
    end

    private

    def enrich_quote(symbol, region)
      data = fetch_quote(symbol)
      price  = data['05. price']          || data[:price]  || MOCK_PRICES.dig(symbol, :price)  || 'N/A'
      change = data['10. change percent'] || data[:change] || MOCK_PRICES.dig(symbol, :change) || 'N/A'
      volume = data['06. volume']         || data[:volume] || MOCK_PRICES.dig(symbol, :volume) || 'N/A'
      signal = begin; RecommendationService.signal_for(symbol); rescue; 'HOLD'; end
      { symbol: symbol, region: region, price: price, change: change, volume: volume, signal: signal }
    end

    def fetch_quote(symbol)
      return @cache[symbol] if cache_fresh? && @cache[symbol]

      result = try_providers(symbol)

      if result
        @cache[symbol]   = result
        @cache_timestamp = Time.now
        result
      else
        warn "[MarketDataService] All providers failed for #{symbol} — using mock data" unless test_env?
        MOCK_PRICES[symbol] || { price: 'N/A', change: 'N/A', volume: 'N/A' }
      end
    end

    def try_providers(symbol)
      providers = [
        [:fetch_from_alpha_vantage, 'Alpha Vantage'],
        [:fetch_from_finnhub,       'Finnhub'],
        [:fetch_from_yahoo,         'Yahoo Finance']
      ]

      providers.each do |method_name, label|
        begin
          result = send(method_name, symbol)
          return result if result && !result.empty?
          warn "[MarketDataService] #{label} returned empty for #{symbol} — trying next provider" unless test_env?
        rescue StandardError => e
          warn "[MarketDataService] #{label} failed for #{symbol} (#{e.class}: #{e.message}) — trying next provider" unless test_env?
        end
      end

      nil
    end

    def fetch_from_alpha_vantage(symbol)
      api_key = ENV['ALPHA_VANTAGE_API_KEY']
      unless api_key
        warn "[MarketDataService] ALPHA_VANTAGE_API_KEY is not set — skipping Alpha Vantage for #{symbol}" unless test_env?
        return nil
      end

      url  = URI("https://www.alphavantage.co/query?function=GLOBAL_QUOTE&symbol=#{symbol}&apikey=#{api_key}")
      res  = Net::HTTP.get_response(url)
      data = JSON.parse(res.body)['Global Quote']
      (data && !data.empty?) ? data : nil
    end

    def fetch_from_finnhub(symbol)
      api_key = ENV['FINNHUB_API_KEY']
      return nil unless api_key

      url  = URI("https://finnhub.io/api/v1/quote?symbol=#{symbol}&token=#{api_key}")
      res  = Net::HTTP.get_response(url)
      data = JSON.parse(res.body)

      return nil unless data['c'] && data['c'] != 0

      {
        '05. price'          => data['c'].to_s,
        '10. change percent' => "#{data['dp']}%",
        '06. volume'         => (data['v'] || 0).to_s
      }
    end

    def fetch_from_yahoo(symbol)
      url = URI("https://query1.finance.yahoo.com/v8/finance/chart/#{symbol}")
      req = Net::HTTP::Get.new(url)
      req['User-Agent'] = 'Mozilla/5.0'

      res  = Net::HTTP.start(url.host, url.port, use_ssl: true) { |http| http.request(req) }
      meta = JSON.parse(res.body).dig('chart', 'result', 0, 'meta')

      return nil unless meta && meta['regularMarketPrice']

      {
        '05. price'          => meta['regularMarketPrice'].to_s,
        '10. change percent' => "#{meta['regularMarketChangePercent']&.round(4)}%",
        '06. volume'         => (meta['regularMarketVolume'] || 0).to_s
      }
    end

    def test_env?
      ENV['RACK_ENV'] == 'test'
    end
  end
end
