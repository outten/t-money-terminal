require 'dotenv'
Dotenv.load(
  File.expand_path('../../.env', __FILE__),
  File.expand_path('../../.credentials', __FILE__)
)
require 'net/http'
require 'json'
require 'time'
require 'fileutils'

class MarketDataService
  CACHE_TTL  = 86400 # 24 hours
  CACHE_FILE = File.expand_path('../../tmp/market_cache.json', __FILE__).freeze

  REGIONS = {
    us:     %w[SPY QQQ AAPL MSFT GOOGL AMZN NVDA JPM],
    japan:  %w[EWJ TM SONY],
    europe: %w[VGK ASML SAP BP]
  }.freeze

  REGION_LABEL = { us: 'US', japan: 'Japan', europe: 'Europe' }.freeze

  # Known ETF/fund symbols — hardcoded type takes precedence over API data
  SYMBOL_TYPES = {
    'SPY' => 'ETF',
    'QQQ' => 'ETF',
    'EWJ' => 'ETF',
    'VGK' => 'ETF'
  }.freeze

  ETF_PROFILES = {
    'SPY' => { name: 'SPDR S&P 500 ETF Trust', description: 'Tracks the S&P 500 index, representing 500 of the largest U.S. publicly traded companies. Managed by State Street Global Advisors.', exchange: 'NYSE Arca', industry: 'ETF — U.S. Large Blend', ticker: 'SPY' },
    'QQQ' => { name: 'Invesco QQQ Trust', description: 'Tracks the Nasdaq-100 Index, providing exposure to 100 of the largest non-financial companies listed on the Nasdaq. Managed by Invesco.', exchange: 'Nasdaq', industry: 'ETF — U.S. Tech Large Blend', ticker: 'QQQ' },
    'EWJ' => { name: 'iShares MSCI Japan ETF', description: 'Tracks the MSCI Japan Index, providing broad exposure to large and mid-cap Japanese equities. Managed by BlackRock.', exchange: 'NYSE Arca', industry: 'ETF — Japan Equities', ticker: 'EWJ' },
    'VGK' => { name: 'Vanguard FTSE Europe ETF', description: 'Tracks the FTSE Developed Europe All Cap Index, providing exposure to stocks in major European markets. Managed by Vanguard.', exchange: 'NYSE Arca', industry: 'ETF — Europe Equities', ticker: 'VGK' }
  }.freeze

  YAHOO_RANGE_MAP = {
    '1d'  => { range: '1d',  interval: '5m'  },
    '1m'  => { range: '1mo', interval: '1d'  },
    '3m'  => { range: '3mo', interval: '1d'  },
    'ytd' => { range: 'ytd', interval: '1wk' },
    '1y'  => { range: '1y',  interval: '1wk' },
    '5y'  => { range: '5y',  interval: '1mo' }
  }.freeze

  MOCK_PRICES = {
    'SPY'  => { price: '520.00', change: '+1.2%', volume: '82000000' },
    'QQQ'  => { price: '448.50', change: '+1.0%', volume: '45000000' },
    'AAPL' => { price: '185.50', change: '-0.5%', volume: '55000000' },
    'MSFT' => { price: '415.75', change: '+0.8%', volume: '22000000' },
    'GOOGL' => { price: '170.20', change: '+0.4%', volume: '24000000' },
    'AMZN' => { price: '200.10', change: '+0.9%', volume: '35000000' },
    'NVDA' => { price: '875.00', change: '+2.1%', volume: '48000000' },
    'JPM'  => { price: '210.30', change: '+0.3%', volume: '10000000' },
    'EWJ'  => { price: '72.10',  change: '+0.3%', volume: '4500000' },
    'TM'   => { price: '198.40', change: '-0.2%', volume: '1200000' },
    'SONY' => { price: '88.60',  change: '+0.5%', volume: '900000' },
    'VGK'  => { price: '69.40',  change: '+0.6%', volume: '2100000' },
    'ASML' => { price: '768.50', change: '+1.3%', volume: '800000' },
    'SAP'  => { price: '218.90', change: '+0.2%', volume: '1100000' },
    'BP'   => { price: '37.80',  change: '-0.4%', volume: '7500000' }
  }.freeze

  @cache            = {}
  @cache_timestamp  = nil
  @persistent_cache = {}  # survives bust_cache! — last known good values
  @cache_timestamps = {}  # per-key timestamp of last successful fetch
  @yahoo_crumb            = nil
  @yahoo_cookie           = nil
  @yahoo_crumb_fetched_at = nil

  # Load disk cache immediately at class load so data survives restarts
  class << self
    def _boot_load
      load_from_disk
    rescue StandardError
      # Silent — missing or corrupt cache file is fine on first run
    end
  end
  _boot_load

  class << self
    def cache_fresh?
      @cache_timestamp && (Time.now - @cache_timestamp) < CACHE_TTL
    end

    def bust_cache!
      @cache           = {}
      @cache_timestamp = nil
      # @persistent_cache and @cache_timestamps are intentionally preserved
    end

    # Full reset — wipes all caches including persistent fallback. Use in tests only.
    def clear_all_caches!
      @cache            = {}
      @cache_timestamp  = nil
      @persistent_cache = {}
      @cache_timestamps = {}
      @yahoo_crumb      = nil
      @yahoo_cookie     = nil
      File.delete(CACHE_FILE) if File.exist?(CACHE_FILE)
    rescue StandardError
      nil
    end

    # Bust all cache entries for a single symbol (live + persistent + disk).
    def bust_cache_for_symbol!(symbol)
      keys_to_clear = [symbol, "analyst:#{symbol}", "profile:#{symbol}"] +
                      YAHOO_RANGE_MAP.keys.map { |p| "candle:#{symbol}:#{p}" }
      keys_to_clear.each do |k|
        @cache.delete(k)
        @persistent_cache.delete(k)
        @cache_timestamps.delete(k)
      end
      # If all live-cache entries are gone reset the global timestamp
      @cache_timestamp = nil if @cache.empty?
      save_to_disk
    end

    # Returns { cached_at: Time|nil, is_stale: bool }
    # is_stale is true when live cache is empty but persistent (stale) data exists
    def cache_info_for(key)
      {
        cached_at: @cache_timestamps[key],
        is_stale:  @cache[key].nil? && !@persistent_cache[key].nil?
      }
    end

    def quote(symbol)
      fetch_quote(symbol)
    end

    def analyst_recommendations(symbol)
      fetch_analyst_recommendations(symbol)
    end

    def company_profile(symbol)
      fetch_company_profile(symbol)
    end

    def historical(symbol, period = '1y')
      fetch_historical(symbol, period)
    end

    # Fetch all historical periods for a symbol efficiently.
    # Tiingo: one call fetching 5y of daily data, sliced into all 6 period caches.
    # Falls back to a single AV TIME_SERIES_WEEKLY call sliced the same way.
    # Returns a hash { period => points_array_or_nil } for each period.
    # Used by the refresh script.
    def prefetch_all_historical(symbol)
      # Tiingo: one call for 5y of daily EOD data, slice into all periods locally
      if ENV['TIINGO_API_KEY']
        api_key    = ENV['TIINGO_API_KEY']
        start_date = Date.today - (5 * 366)
        url = URI("https://api.tiingo.com/tiingo/daily/#{symbol}/prices" \
                  "?startDate=#{start_date}&resampleFreq=daily&token=#{api_key}")
        req = Net::HTTP::Get.new(url)
        req['Content-Type'] = 'application/json'
        res = Net::HTTP.start(url.host, url.port, use_ssl: true, read_timeout: 15, open_timeout: 5) { |http| http.request(req) }

        if res.is_a?(Net::HTTPSuccess)
          data = JSON.parse(res.body)
          if data.is_a?(Array) && !data.empty?
            all_points = data.filter_map { |row|
              date  = row['date']&.slice(0, 10)
              close = row['adjClose'] || row['close']
              next unless date && close
              { date: date, close: close.to_f.round(2) }
            }.sort_by { |p| p[:date] }

            today   = Date.today
            cutoffs = {
              '1d'  => today - 1,
              '1m'  => today - 30,
              '3m'  => today - 90,
              'ytd' => Date.new(today.year, 1, 1),
              '1y'  => today - 365,
              '5y'  => today - (5 * 365)
            }

            results = {}
            cutoffs.each do |period, cutoff|
              points = all_points.select { |p| Date.parse(p[:date]) >= cutoff }
              if points.any?
                store_cache("candle:#{symbol}:#{period}", points)
                results[period] = points
              else
                results[period] = nil
              end
            end
            return results if results.values.any?
          end
        else
          warn "[MarketDataService] Tiingo prefetch returned HTTP #{res.code} for #{symbol}" unless test_env?
        end
      end

      # Fall back to single AV TIME_SERIES_WEEKLY call
      api_key = ENV['ALPHA_VANTAGE_API_KEY']
      return {} unless api_key

      url  = URI("https://www.alphavantage.co/query?function=TIME_SERIES_WEEKLY&symbol=#{symbol}&apikey=#{api_key}")
      res  = Net::HTTP.get_response(url)
      data = JSON.parse(res.body)

      series = data['Weekly Time Series']
      return { rate_limited: data.key?('Information') || data.key?('Note') } unless series && !series.empty?

      all_points = series.map { |date, vals|
        { date: date, close: vals['4. close'].to_f.round(2) }
      }.sort_by { |p| p[:date] }

      today   = Date.today
      cutoffs = {
        '1d'  => today - 1,
        '1m'  => today - 30,
        '3m'  => today - 90,
        'ytd' => Date.new(today.year, 1, 1),
        '1y'  => today - 365,
        '5y'  => today - (5 * 365)
      }

      results = {}
      cutoffs.each do |period, cutoff|
        key    = "candle:#{symbol}:#{period}"
        points = all_points.select { |p| Date.parse(p[:date]) >= cutoff }
        if points.any?
          store_cache(key, points)
          results[period] = points
        else
          results[period] = nil
        end
      end
      results
    rescue StandardError => e
      warn "[MarketDataService] prefetch_all_historical failed for #{symbol}: #{e.message}"
      {}
    end

    def symbol_type(symbol)
      return SYMBOL_TYPES[symbol] if SYMBOL_TYPES.key?(symbol)

      # Fall back to cached Finnhub profile type field (no extra API call)
      profile = @cache["profile:#{symbol}"] || @persistent_cache["profile:#{symbol}"]
      if profile && profile[:finnhub_type]
        type_map = { 'EQS' => 'Equity', 'ETF' => 'ETF', 'ADR' => 'ADR', 'FUND' => 'Fund' }
        return type_map[profile[:finnhub_type]] || profile[:finnhub_type]
      end

      'Equity'
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
      type   = symbol_type(symbol)
      { symbol: symbol, region: region, price: price, change: change, volume: volume, signal: signal, type: type }
    end

    def fetch_quote(symbol)
      return @cache[symbol] if cache_fresh? && @cache[symbol]

      result = try_providers(symbol)

      if result
        store_cache(symbol, result)
        @cache_timestamp = Time.now
        return result
      end

      if @persistent_cache[symbol]
        warn "[MarketDataService] All providers failed for #{symbol} — serving stale cache" unless test_env?
        return @persistent_cache[symbol]
      end

      warn "[MarketDataService] All providers failed for #{symbol} — using mock data" unless test_env?
      MOCK_PRICES[symbol] || { price: 'N/A', change: 'N/A', volume: 'N/A' }
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

    # Store value in both live cache and persistent fallback cache
    def store_cache(key, value)
      @cache[key]            = value
      @persistent_cache[key] = value
      @cache_timestamps[key] = Time.now
      save_to_disk
    end

    def fetch_analyst_recommendations(symbol)
      key = "analyst:#{symbol}"
      return @cache[key] if @cache[key]

      api_key = ENV['FINNHUB_API_KEY']
      unless api_key
        return @persistent_cache[key]
      end

      url  = URI("https://finnhub.io/api/v1/stock/recommendation?symbol=#{symbol}&token=#{api_key}")
      res  = Net::HTTP.get_response(url)
      data = JSON.parse(res.body)

      unless data.is_a?(Array) && !data.empty?
        return @persistent_cache[key]
      end

      latest = data.first
      result = {
        strong_buy:  latest['strongBuy'].to_i,
        buy:         latest['buy'].to_i,
        hold:        latest['hold'].to_i,
        sell:        latest['sell'].to_i,
        strong_sell: latest['strongSell'].to_i,
        period:      latest['period']
      }
      store_cache(key, result)
      result
    rescue StandardError => e
      warn "[MarketDataService] Finnhub analyst fetch failed for #{symbol}: #{e.message}" unless test_env?
      @persistent_cache[key]
    end

    def fetch_company_profile(symbol)
      key = "profile:#{symbol}"
      return @cache[key] if @cache[key]

      # Use hardcoded profile for known ETFs
      if ETF_PROFILES.key?(symbol)
        profile = ETF_PROFILES[symbol].dup
        store_cache(key, profile)
        return profile
      end

      api_key = ENV['FINNHUB_API_KEY']
      unless api_key
        return @persistent_cache[key]
      end

      url  = URI("https://finnhub.io/api/v1/stock/profile2?symbol=#{symbol}&token=#{api_key}")
      res  = Net::HTTP.get_response(url)
      data = JSON.parse(res.body)

      unless data && !data.empty?
        return @persistent_cache[key]
      end

      result = {
        name:          data['name'],
        description:   data['description'] || "#{data['name']} (#{symbol})",
        exchange:      data['exchange'],
        industry:      data['finnhubIndustry'],
        market_cap:    data['marketCapitalization'],
        ipo:           data['ipo'],
        logo:          data['logo'],
        weburl:        data['weburl'],
        finnhub_type:  data['type'],
        ticker:        symbol,
        source: 'Finnhub'
      }
      store_cache(key, result)
      result
    rescue StandardError => e
      warn "[MarketDataService] Finnhub profile fetch failed for #{symbol}: #{e.message}" unless test_env?
      @persistent_cache[key]
    end

    def fetch_historical(symbol, period = '1y')
      key = "candle:#{symbol}:#{period}"
      return @cache[key] if @cache[key]

      range_cfg = YAHOO_RANGE_MAP[period] || YAHOO_RANGE_MAP['1y']
      # Tiingo primary; Yahoo crumb auth secondary; Alpha Vantage TIME_SERIES_WEEKLY tertiary
      result = fetch_historical_from_tiingo(symbol, period) ||
               fetch_historical_from_yahoo(symbol, range_cfg) ||
               fetch_historical_from_alpha_vantage(symbol, period)

      if result
        store_cache(key, result)
        return result
      end

      # Stale fallback
      if @persistent_cache[key]
        warn "[MarketDataService] Historical fetch failed for #{symbol}:#{period} — serving stale cache" unless test_env?
        return @persistent_cache[key]
      end

      nil
    end

    def fetch_historical_from_tiingo(symbol, period)
      api_key = ENV['TIINGO_API_KEY']
      return nil unless api_key

      today  = Date.today
      start_date = case period
                   when '1d'  then today - 5      # go back a few days; slice to last 1-2 points
                   when '1m'  then today - 31
                   when '3m'  then today - 92
                   when 'ytd' then Date.new(today.year, 1, 1)
                   when '1y'  then today - 366
                   when '5y'  then today - (5 * 366)
                   else            today - 366
                   end

      url = URI("https://api.tiingo.com/tiingo/daily/#{symbol}/prices" \
                "?startDate=#{start_date}&resampleFreq=daily&token=#{api_key}")
      req = Net::HTTP::Get.new(url)
      req['Content-Type'] = 'application/json'

      res = Net::HTTP.start(url.host, url.port, use_ssl: true, read_timeout: 10, open_timeout: 5) { |http| http.request(req) }

      unless res.is_a?(Net::HTTPSuccess)
        warn "[MarketDataService] Tiingo returned HTTP #{res.code} for #{symbol}" unless test_env?
        return nil
      end

      data = JSON.parse(res.body)
      return nil unless data.is_a?(Array) && !data.empty?

      points = data.filter_map do |row|
        date  = row['date']&.slice(0, 10)
        close = row['adjClose'] || row['close']
        next unless date && close
        { date: date, close: close.to_f.round(2) }
      end.sort_by { |p| p[:date] }

      points.empty? ? nil : points
    rescue StandardError => e
      warn "[MarketDataService] Tiingo historical fetch failed for #{symbol}: #{e.message}" unless test_env?
      nil
    end

    def fetch_yahoo_crumb_and_cookie
      # Cache the crumb/cookie for 1 hour
      return [@yahoo_crumb, @yahoo_cookie] if @yahoo_crumb && @yahoo_crumb_fetched_at && (Time.now - @yahoo_crumb_fetched_at) < 3600

      # Step 1: hit Yahoo Finance to establish a session and collect cookies
      consent_url = URI('https://finance.yahoo.com/')
      consent_req = Net::HTTP::Get.new(consent_url)
      consent_req['User-Agent'] = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36'
      consent_res = Net::HTTP.start(consent_url.host, consent_url.port, use_ssl: true, read_timeout: 10, open_timeout: 5) { |h| h.request(consent_req) }
      raw_cookies = Array(consent_res.get_fields('set-cookie') || [])
      cookie_str  = raw_cookies.map { |c| c.split(';').first }.join('; ')

      # Step 2: fetch the crumb using the session cookie
      crumb_url = URI('https://query1.finance.yahoo.com/v1/test/getcrumb')
      crumb_req = Net::HTTP::Get.new(crumb_url)
      crumb_req['User-Agent'] = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36'
      crumb_req['Cookie']     = cookie_str
      crumb_res = Net::HTTP.start(crumb_url.host, crumb_url.port, use_ssl: true, read_timeout: 10, open_timeout: 5) { |h| h.request(crumb_req) }
      crumb = crumb_res.body.strip

      return [nil, nil] if crumb.empty? || crumb.include?('<')

      @yahoo_crumb           = crumb
      @yahoo_cookie          = cookie_str
      @yahoo_crumb_fetched_at = Time.now
      [crumb, cookie_str]
    rescue StandardError => e
      warn "[MarketDataService] Yahoo crumb fetch failed: #{e.message}" unless test_env?
      [nil, nil]
    end

    def fetch_historical_from_yahoo(symbol, range_cfg)
      crumb, cookie = fetch_yahoo_crumb_and_cookie

      hosts = %w[query1.finance.yahoo.com query2.finance.yahoo.com]
      hosts.each do |host|
        begin
          path = "/v8/finance/chart/#{symbol}?range=#{range_cfg[:range]}&interval=#{range_cfg[:interval]}&includePrePost=false"
          path += "&crumb=#{URI.encode_uri_component(crumb)}" if crumb
          url  = URI("https://#{host}#{path}")
          req  = Net::HTTP::Get.new(url)
          req['User-Agent']      = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36'
          req['Accept']          = 'application/json, text/plain, */*'
          req['Accept-Language'] = 'en-US,en;q=0.9'
          req['Referer']         = 'https://finance.yahoo.com/'
          req['Cookie']          = cookie if cookie

          res = Net::HTTP.start(url.host, url.port, use_ssl: true, read_timeout: 10, open_timeout: 5) { |http| http.request(req) }

          unless res.is_a?(Net::HTTPSuccess)
            warn "[MarketDataService] Yahoo (#{host}) returned HTTP #{res.code} for #{symbol}" unless test_env?
            # If 429, clear crumb so next request re-fetches it
            if res.code == '429'
              @yahoo_crumb = nil
              @yahoo_cookie = nil
            end
            next
          end

          parsed = JSON.parse(res.body)
          result = parsed.dig('chart', 'result', 0)
          next unless result

          timestamps = result['timestamp'] || []
          closes     = result.dig('indicators', 'quote', 0, 'close') || []

          points = timestamps.zip(closes).filter_map do |ts, close|
            next unless ts && close
            { date: Time.at(ts).utc.strftime('%Y-%m-%d'), close: close.round(2) }
          end

          return points unless points.empty?
        rescue StandardError => e
          warn "[MarketDataService] Yahoo historical (#{host}) failed for #{symbol}: #{e.message}" unless test_env?
        end
      end
      nil
    end

    def fetch_historical_from_alpha_vantage(symbol, period)
      api_key = ENV['ALPHA_VANTAGE_API_KEY']
      return nil unless api_key

      # Use weekly series — one API call covers all periods 1m through 5y
      url  = URI("https://www.alphavantage.co/query?function=TIME_SERIES_WEEKLY&symbol=#{symbol}&apikey=#{api_key}")
      res  = Net::HTTP.get_response(url)
      data = JSON.parse(res.body)

      series = data['Weekly Time Series']
      return nil unless series && !series.empty?

      # series is a Hash { "YYYY-MM-DD" => { "4. close" => "...", ... } }, newest first
      all_points = series.map do |date, vals|
        { date: date, close: vals['4. close'].to_f.round(2) }
      end.sort_by { |p| p[:date] }

      # Slice by period
      cutoff = case period
               when '1d'  then Date.today - 1
               when '1m'  then Date.today - 30
               when '3m'  then Date.today - 90
               when 'ytd' then Date.new(Date.today.year, 1, 1)
               when '1y'  then Date.today - 365
               when '5y'  then Date.today - (5 * 365)
               else             Date.today - 365
               end

      points = all_points.select { |p| Date.parse(p[:date]) >= cutoff }
      points.empty? ? nil : points
    rescue StandardError => e
      warn "[MarketDataService] Alpha Vantage historical fetch failed for #{symbol}: #{e.message}" unless test_env?
      nil
    end

    # ---- Disk persistence ----

    def save_to_disk
      return if test_env?
      FileUtils.mkdir_p(File.dirname(CACHE_FILE))
      payload = {
        'cache'      => serialize_cache(@persistent_cache),
        'timestamps' => @cache_timestamps.transform_values { |t| t&.iso8601 }
      }
      File.write(CACHE_FILE, JSON.generate(payload))
    rescue StandardError => e
      warn "[MarketDataService] Failed to save cache to disk: #{e.message}"
    end

    def load_from_disk
      return unless File.exist?(CACHE_FILE)
      payload    = JSON.parse(File.read(CACHE_FILE))
      raw_cache  = payload['cache']      || {}
      raw_stamps = payload['timestamps'] || {}

      raw_cache.each do |k, v|
        @persistent_cache[k] = deserialize_value(k, v)
      end
      raw_stamps.each do |k, ts|
        @cache_timestamps[k] = ts ? Time.parse(ts) : nil
      end
    rescue StandardError => e
      warn "[MarketDataService] Failed to load cache from disk: #{e.message}"
    end

    def serialize_cache(cache_hash)
      cache_hash.transform_values do |v|
        case v
        when Array
          v.map { |item| item.is_a?(Hash) ? item.transform_keys(&:to_s) : item }
        when Hash
          v.transform_keys(&:to_s)
        else
          v
        end
      end
    end

    def deserialize_value(key, value)
      if key.start_with?('analyst:', 'profile:')
        value.is_a?(Hash) ? value.transform_keys(&:to_sym) : value
      elsif key.start_with?('candle:')
        value.is_a?(Array) ? value.map { |h| h.is_a?(Hash) ? h.transform_keys(&:to_sym) : h } : value
      else
        value  # quote data keeps string keys as-is
      end
    end
  end
end
