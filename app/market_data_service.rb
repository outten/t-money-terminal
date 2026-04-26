require 'dotenv'
Dotenv.load(
  File.expand_path('../../.env', __FILE__),
  File.expand_path('../../.credentials', __FILE__)
)
require 'net/http'
require 'json'
require 'time'
require 'fileutils'
require_relative 'health_registry'

class MarketDataService
  CACHE_TTL  = 3600 # 1 hour
  CACHE_DIR  = File.expand_path('../../data/cache', __FILE__).freeze
  CACHE_FILE = File.join(CACHE_DIR, 'market_cache.json').freeze
  LEGACY_CACHE_FILE = File.expand_path('../../.cache/market_cache.json', __FILE__).freeze
  LEGACY_TMP_CACHE_FILE = File.expand_path('../../tmp/market_cache.json', __FILE__).freeze

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
    'SONY' => { price: '21.00',  change: '+0.5%', volume: '900000' },
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
  @yahoo_rate_limited_until = nil
  @tiingo_quote_rate_limited_until = nil
  @tiingo_hist_rate_limited_until  = nil
  @av_quote_rate_limited_until     = nil

  class << self
    def cache_fresh?
      @cache_timestamp && (Time.now - @cache_timestamp) < CACHE_TTL
    end

    def cache_entry_fresh?(key)
      ts = @cache_timestamps[key]
      ts && (Time.now - ts) < CACHE_TTL
    end

    def read_live_cache(key)
      value = @cache[key]
      return nil unless value

      return value if cache_entry_fresh?(key)

      # Expired live entry: drop it so the caller refetches and can fall back to persistent cache.
      @cache.delete(key)
      nil
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
      @yahoo_crumb_fetched_at = nil
      @yahoo_rate_limited_until = nil
      @tiingo_quote_rate_limited_until = nil
      @tiingo_hist_rate_limited_until  = nil
      @av_quote_rate_limited_until     = nil
      File.delete(CACHE_FILE) if File.exist?(CACHE_FILE)
      File.delete(LEGACY_CACHE_FILE) if File.exist?(LEGACY_CACHE_FILE)
      File.delete(LEGACY_TMP_CACHE_FILE) if File.exist?(LEGACY_TMP_CACHE_FILE)
      
      # Delete hierarchical cache directories
      %w[quotes historical analyst profiles other].each do |subdir|
        dir_path = File.join(CACHE_DIR, subdir)
        FileUtils.rm_rf(dir_path) if Dir.exist?(dir_path)
      end
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
        
        # Delete hierarchical cache files
        type, sym, period = _parse_cache_key(k)
        delete_cache_entry(type, sym, period)
      end
      # If all live-cache entries are gone reset the global timestamp
      @cache_timestamp = nil if @cache.empty?
      save_to_disk
    end

    # Live-only refresh for a symbol.
    # Keeps persistent cache/timestamps so historical pages still have fallback data
    # if providers are temporarily rate-limited.
    def refresh_symbol_live_cache!(symbol)
      keys_to_clear = [symbol, "analyst:#{symbol}", "profile:#{symbol}"] +
                      YAHOO_RANGE_MAP.keys.map { |p| "candle:#{symbol}:#{p}" }
      keys_to_clear.each { |k| @cache.delete(k) }
      @cache_timestamp = nil if @cache.empty?
    end

    # Returns { cached_at: Time|nil, is_stale: bool }
    # is_stale is true when live cache is empty but persistent (stale) data exists
    def cache_info_for(key)
      live = read_live_cache(key)
      {
        cached_at: @cache_timestamps[key],
        is_stale:  live.nil? && !@persistent_cache[key].nil?
      }
    end

    # Returns an array of hashes describing every known cache entry:
    #   { key:, type:, symbol:, period:, cached_at:, is_stale:, size: }
    def cache_summary
      all_keys = (@cache.keys + @persistent_cache.keys).uniq
      all_keys.map do |key|
        type, symbol, period = _parse_cache_key(key)
        entry    = @cache[key] || @persistent_cache[key]
        ts       = @cache_timestamps[key]
        stale    = (!cache_entry_fresh?(key) || @cache[key].nil?) && !@persistent_cache[key].nil?
        size     = case entry
                   when Array then entry.length
                   when Hash  then entry.keys.length
                   else            1
                   end
        { key: key, type: type, symbol: symbol, period: period,
          cached_at: ts, is_stale: stale, size: size }
      end.sort_by { |e| e[:key] }
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
      # Yahoo primary: one 5y monthly call gives data to slice all periods locally
      yahoo_5y = fetch_historical_from_yahoo(symbol, YAHOO_RANGE_MAP['5y'])
      if yahoo_5y && !yahoo_5y.empty?
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
          points = yahoo_5y.select { |p| Date.parse(p[:date]) >= cutoff }
          if points.any?
            store_cache("candle:#{symbol}:#{period}", points)
            results[period] = points
          else
            results[period] = nil
          end
        end
        return results if results.values.any?
      end

      # FMP free-tier historical: one call returns ~5y of daily EOD closes.
      # Shape: [{ symbol, date: 'YYYY-MM-DD', price, volume }] (newest first).
      if ENV['FMP_API_KEY'] && !ENV['FMP_API_KEY'].empty?
        fmp_points = fetch_fmp_historical_full(symbol)
        if fmp_points && !fmp_points.empty?
          today = Date.today
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
            points = fmp_points.select { |p| Date.parse(p[:date]) >= cutoff }
            if points.any?
              store_cache("candle:#{symbol}:#{period}", points)
              results[period] = points
            else
              results[period] = nil
            end
          end
          return results if results.values.any?
        end
      end

      # Tiingo: one call for 5y of daily EOD data, slice into all periods locally
      if ENV['TIINGO_API_KEY'] && (!@tiingo_hist_rate_limited_until || Time.now >= @tiingo_hist_rate_limited_until)
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
              close = row['close'] || row['adjClose']
              next unless date && close
              {
                date:      date,
                open:      (row['open']   || row['adjOpen'])&.to_f&.round(2),
                high:      (row['high']   || row['adjHigh'])&.to_f&.round(2),
                low:       (row['low']    || row['adjLow'])&.to_f&.round(2),
                close:     close.to_f.round(2),
                adj_close: row['adjClose']&.to_f&.round(4),
                volume:    (row['volume'] || row['adjVolume'])&.to_i
              }
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
          if res.code == '429'
            @tiingo_hist_rate_limited_until = Time.now + 900
            warn "[MarketDataService] Tiingo historical rate limited for #{symbol}" unless test_env?
          else
            warn "[MarketDataService] Tiingo prefetch returned HTTP #{res.code} for #{symbol}" unless test_env?
          end
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
        {
          date:   date,
          open:   vals['1. open']&.to_f&.round(2),
          high:   vals['2. high']&.to_f&.round(2),
          low:    vals['3. low']&.to_f&.round(2),
          close:  vals['4. close'].to_f.round(2),
          volume: vals['5. volume']&.to_i
        }
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
      cached = read_live_cache(symbol)
      return cached if cached

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
        [:fetch_from_tiingo_quote,  'Tiingo',        'tiingo_quote'],
        [:fetch_from_alpha_vantage, 'Alpha Vantage', 'alpha_vantage_quote'],
        [:fetch_from_finnhub,       'Finnhub',       'finnhub_quote'],
        [:fetch_from_yahoo,         'Yahoo Finance', 'yahoo_quote']
      ]

      providers.each do |method_name, label, slug|
        begin
          result = HealthRegistry.measure(slug, reason_on_nil: 'empty_or_rate_limited') do
            send(method_name, symbol)
          end
          return result if result && !result.empty?
          # nil means provider skipped/rate-limited; only warn on genuinely empty responses
          warn "[MarketDataService] #{label} returned empty for #{symbol} — trying next provider" if result == {} && !test_env?
        rescue StandardError => e
          warn "[MarketDataService] #{label} failed for #{symbol} (#{e.class}: #{e.message}) — trying next provider" unless test_env?
        end
      end

      nil
    end

    def fetch_from_tiingo_quote(symbol)
      if @tiingo_quote_rate_limited_until && Time.now < @tiingo_quote_rate_limited_until
        return nil
      end

      api_key = ENV['TIINGO_API_KEY']
      return nil unless api_key

      url = URI("https://api.tiingo.com/tiingo/daily/#{symbol}/prices?token=#{api_key}")
      req = Net::HTTP::Get.new(url)
      req['Content-Type'] = 'application/json'
      res = Net::HTTP.start(url.host, url.port, use_ssl: true, read_timeout: 10, open_timeout: 5) { |http| http.request(req) }

      if res.is_a?(Net::HTTPTooManyRequests)
        @tiingo_quote_rate_limited_until = Time.now + 900
        warn "[MarketDataService] Tiingo quote rate limited for #{symbol}" unless test_env?
        return nil
      end

      return nil unless res.is_a?(Net::HTTPSuccess)

      data = JSON.parse(res.body)
      return nil unless data.is_a?(Array) && !data.empty?

      row = data.last
      close   = row['close'] || row['adjClose']
      high    = row['high'] || row['adjHigh']
      low     = row['low'] || row['adjLow']
      open    = row['open'] || row['adjOpen']
      volume  = row['volume'] || row['adjVolume'] || 0
      return nil unless close && close != 0

      prev_close = data.length > 1 ? (data[-2]['close'] || data[-2]['adjClose']).to_f : close.to_f
      change_pct = prev_close.zero? ? 0 : ((close.to_f - prev_close) / prev_close * 100).round(4)

      {
        '05. price'          => close.to_s,
        '10. change percent' => "#{change_pct}%",
        '06. volume'         => volume.to_s,
        '02. open'           => open.to_s,
        '03. high'           => high.to_s,
        '04. low'            => low.to_s
      }
    rescue StandardError => e
      warn "[MarketDataService] Tiingo quote fetch failed for #{symbol}: #{e.message}" unless test_env?
      nil
    end

    def fetch_from_alpha_vantage(symbol)
      if @av_quote_rate_limited_until && Time.now < @av_quote_rate_limited_until
        return nil
      end

      api_key = ENV['ALPHA_VANTAGE_API_KEY']
      unless api_key
        warn "[MarketDataService] ALPHA_VANTAGE_API_KEY is not set — skipping Alpha Vantage for #{symbol}" unless test_env?
        return nil
      end

      url  = URI("https://www.alphavantage.co/query?function=GLOBAL_QUOTE&symbol=#{symbol}&apikey=#{api_key}")
      res  = Net::HTTP.get_response(url)
      body = JSON.parse(res.body)

      if body.key?('Information') || body.key?('Note')
        @av_quote_rate_limited_until = Time.now + 3600
        warn "[MarketDataService] Alpha Vantage rate limited for #{symbol}" unless test_env?
        return nil
      end

      data = body['Global Quote']
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
      
      # Also write to hierarchical cache
      type, symbol, period = _parse_cache_key(key)
      write_cache_entry(type, symbol, value, period)
    end

    def fetch_analyst_recommendations(symbol)
      key = "analyst:#{symbol}"
      cached = read_live_cache(key)
      return cached if cached

      api_key = ENV['FINNHUB_API_KEY']
      unless api_key
        return @persistent_cache[key]
      end

      result = HealthRegistry.measure('finnhub_analyst', reason_on_nil: 'empty_response') do
        url  = URI("https://finnhub.io/api/v1/stock/recommendation?symbol=#{symbol}&token=#{api_key}")
        res  = Net::HTTP.get_response(url)
        data = JSON.parse(res.body)
        next nil unless data.is_a?(Array) && !data.empty?

        latest = data.first
        {
          strong_buy:  latest['strongBuy'].to_i,
          buy:         latest['buy'].to_i,
          hold:        latest['hold'].to_i,
          sell:        latest['sell'].to_i,
          strong_sell: latest['strongSell'].to_i,
          period:      latest['period']
        }
      end

      if result
        store_cache(key, result)
        result
      else
        @persistent_cache[key]
      end
    rescue StandardError => e
      warn "[MarketDataService] Finnhub analyst fetch failed for #{symbol}: #{e.message}" unless test_env?
      @persistent_cache[key]
    end

    def fetch_company_profile(symbol)
      key = "profile:#{symbol}"
      cached = read_live_cache(key)
      return cached if cached

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

      result = HealthRegistry.measure('finnhub_profile', reason_on_nil: 'empty_response') do
        url  = URI("https://finnhub.io/api/v1/stock/profile2?symbol=#{symbol}&token=#{api_key}")
        res  = Net::HTTP.get_response(url)
        data = JSON.parse(res.body)
        next nil unless data && !data.empty?

        {
          name:          data['name'],
          description:   data['description'] || "#{data['name']} (#{symbol})",
          exchange:      data['exchange'],
          industry:      data['finnhubIndustry'],
          market_cap:    data['marketCapitalization'],
          market_cap_currency: data['currency'],
          ipo:           data['ipo'],
          logo:          data['logo'],
          weburl:        data['weburl'],
          finnhub_type:  data['type'],
          ticker:        symbol,
          source: 'Finnhub'
        }
      end

      if result
        store_cache(key, result)
        result
      else
        @persistent_cache[key]
      end
    rescue StandardError => e
      warn "[MarketDataService] Finnhub profile fetch failed for #{symbol}: #{e.message}" unless test_env?
      @persistent_cache[key]
    end

    def fetch_historical(symbol, period = '1y')
      key = "candle:#{symbol}:#{period}"
      cached = read_live_cache(key)
      return cached if cached

      # Bootstrap all periods from a single prefetch pass (Yahoo-first),
      # then serve the requested period from that warmed cache.
      prefetched = prefetch_all_historical(symbol)
      if prefetched && prefetched[period] && !prefetched[period].empty?
        return prefetched[period]
      end

      range_cfg = YAHOO_RANGE_MAP[period] || YAHOO_RANGE_MAP['1y']
      # Yahoo primary (has intraday for 1d); FMP is the most reliable free-tier
      # daily source for US-listed symbols; then Finnhub, Tiingo, Alpha Vantage.
      result = HealthRegistry.measure('yahoo_chart',     reason_on_nil: 'empty_or_rate_limited') { fetch_historical_from_yahoo(symbol, range_cfg) } ||
               HealthRegistry.measure('fmp_history',     reason_on_nil: 'empty_or_rate_limited') { fetch_historical_from_fmp(symbol, period) } ||
               HealthRegistry.measure('finnhub_candle',  reason_on_nil: 'empty_or_rate_limited') { fetch_historical_from_finnhub(symbol, period) } ||
               HealthRegistry.measure('tiingo_history',  reason_on_nil: 'empty_or_rate_limited') { fetch_historical_from_tiingo(symbol, period) } ||
               HealthRegistry.measure('alpha_vantage_weekly', reason_on_nil: 'empty_or_rate_limited') { fetch_historical_from_alpha_vantage(symbol, period) }

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
      if @tiingo_hist_rate_limited_until && Time.now < @tiingo_hist_rate_limited_until
        return nil
      end

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
        if res.code == '429'
          @tiingo_hist_rate_limited_until = Time.now + 900
          warn "[MarketDataService] Tiingo historical rate limited for #{symbol}" unless test_env?
        else
          warn "[MarketDataService] Tiingo returned HTTP #{res.code} for #{symbol}" unless test_env?
        end
        return nil
      end

      data = JSON.parse(res.body)
      return nil unless data.is_a?(Array) && !data.empty?

      points = data.filter_map do |row|
        date  = row['date']&.slice(0, 10)
        close = row['close'] || row['adjClose']
        next unless date && close
        {
          date:      date,
          open:      (row['open']   || row['adjOpen'])&.to_f&.round(2),
          high:      (row['high']   || row['adjHigh'])&.to_f&.round(2),
          low:       (row['low']    || row['adjLow'])&.to_f&.round(2),
          close:     close.to_f.round(2),
          adj_close: row['adjClose']&.to_f&.round(4),
          volume:    (row['volume'] || row['adjVolume'])&.to_i
        }
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
      if @yahoo_rate_limited_until && Time.now < @yahoo_rate_limited_until
        return nil
      end

      hosts = %w[query1.finance.yahoo.com query2.finance.yahoo.com]

      # First attempt: no crumb (works when Yahoo isn't requesting auth, saves 2 extra requests)
      hosts.each do |host|
        result = _yahoo_chart_request(symbol, host, range_cfg, crumb: nil, cookie: nil)
        return result if result
      end

      # Second attempt: crumb + cookie auth
      crumb, cookie = fetch_yahoo_crumb_and_cookie
      return nil unless crumb

      hosts.each do |host|
        result = _yahoo_chart_request(symbol, host, range_cfg, crumb: crumb, cookie: cookie)
        return result if result
      end

      nil
    end

    def _yahoo_chart_request(symbol, host, range_cfg, crumb:, cookie:)
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
        if res.code == '429'
          @yahoo_rate_limited_until = Time.now + 300
          @yahoo_crumb = nil
          @yahoo_cookie = nil
        end
        return nil
      end

      parsed = JSON.parse(res.body)
      result = parsed.dig('chart', 'result', 0)
      return nil unless result

      timestamps = result['timestamp'] || []
      closes     = result.dig('indicators', 'quote', 0, 'close') || []
      adjcloses  = result.dig('indicators', 'adjclose', 0, 'adjclose') || []

      opens   = result.dig('indicators', 'quote', 0, 'open')   || []
      highs   = result.dig('indicators', 'quote', 0, 'high')   || []
      lows    = result.dig('indicators', 'quote', 0, 'low')    || []
      volumes = result.dig('indicators', 'quote', 0, 'volume') || []

      points = timestamps.each_with_index.filter_map do |ts, idx|
        close = closes[idx] || adjcloses[idx]
        next unless ts && close
        {
          date:      Time.at(ts).utc.strftime('%Y-%m-%d'),
          open:      opens[idx]&.to_f&.round(2),
          high:      highs[idx]&.to_f&.round(2),
          low:       lows[idx]&.to_f&.round(2),
          close:     close.to_f.round(2),
          adj_close: adjcloses[idx]&.to_f&.round(4),
          volume:    volumes[idx]&.to_i
        }
      end

      points.empty? ? nil : points
    rescue StandardError => e
      warn "[MarketDataService] Yahoo historical (#{host}) failed for #{symbol}: #{e.message}" unless test_env?
      nil
    end

    def fetch_historical_from_finnhub(symbol, period)
      api_key = ENV['FINNHUB_API_KEY']
      return nil unless api_key

      now = Time.now.to_i
      from = case period
             when '1d'  then (Time.now - (2 * 86_400)).to_i
             when '1m'  then (Time.now - (31 * 86_400)).to_i
             when '3m'  then (Time.now - (92 * 86_400)).to_i
             when 'ytd' then Time.new(Time.now.year, 1, 1).to_i
             when '1y'  then (Time.now - (366 * 86_400)).to_i
             when '5y'  then (Time.now - ((5 * 366) * 86_400)).to_i
             else            (Time.now - (366 * 86_400)).to_i
             end

      url = URI("https://finnhub.io/api/v1/stock/candle?symbol=#{symbol}&resolution=D&from=#{from}&to=#{now}&token=#{api_key}")
      res = Net::HTTP.get_response(url)
      return nil unless res.is_a?(Net::HTTPSuccess)

      data = JSON.parse(res.body)
      return nil unless data['s'] == 'ok'

      closes  = data['c'] || []
      opens   = data['o'] || []
      highs   = data['h'] || []
      lows    = data['l'] || []
      volumes = data['v'] || []
      times   = data['t'] || []
      points = times.each_with_index.filter_map do |ts, idx|
        close = closes[idx]
        next unless ts && close
        {
          date:   Time.at(ts).utc.strftime('%Y-%m-%d'),
          open:   opens[idx]&.to_f&.round(2),
          high:   highs[idx]&.to_f&.round(2),
          low:    lows[idx]&.to_f&.round(2),
          close:  close.to_f.round(2),
          volume: volumes[idx]&.to_i
        }
      end

      points.empty? ? nil : points
    rescue StandardError => e
      warn "[MarketDataService] Finnhub historical fetch failed for #{symbol}: #{e.message}" unless test_env?
      nil
    end

    # FMP free-tier historical. Returns [{date:, open:, high:, low:, close:, volume:}]
    # sorted oldest→newest for the requested period window, or nil on failure.
    # Uses /historical-price-eod/full for OHLCV.
    def fetch_historical_from_fmp(symbol, period)
      all_points = fetch_fmp_historical_full(symbol)
      return nil if all_points.nil? || all_points.empty?

      today = Date.today
      cutoff = case period
               when '1d'  then today - 1
               when '1m'  then today - 30
               when '3m'  then today - 90
               when 'ytd' then Date.new(today.year, 1, 1)
               when '1y'  then today - 365
               when '5y'  then today - (5 * 365)
               else            today - 365
               end

      points = all_points.select { |p| Date.parse(p[:date]) >= cutoff }
      points.empty? ? nil : points
    rescue StandardError => e
      warn "[MarketDataService] FMP historical fetch failed for #{symbol}: #{e.message}" unless test_env?
      nil
    end

    # Shared FMP fetch: returns the full 5y series as [{date:, close:}] sorted
    # oldest→newest. Callers slice by period. Returns nil on any error.
    def fetch_fmp_historical_full(symbol)
      api_key = ENV['FMP_API_KEY']
      return nil unless api_key && !api_key.empty?

      url = URI("https://financialmodelingprep.com/stable/historical-price-eod/full" \
                "?symbol=#{symbol}&apikey=#{api_key}")
      res = Net::HTTP.get_response(url)
      unless res.is_a?(Net::HTTPSuccess)
        warn "[MarketDataService] FMP historical returned HTTP #{res.code} for #{symbol}" unless test_env?
        return nil
      end

      data = JSON.parse(res.body)
      return nil unless data.is_a?(Array) && !data.empty?

      data.filter_map do |row|
        date  = row['date']
        close = row['close'] || row['price']
        next unless date && close
        {
          date:      date.slice(0, 10),
          open:      row['open']&.to_f&.round(2),
          high:      row['high']&.to_f&.round(2),
          low:       row['low']&.to_f&.round(2),
          close:     close.to_f.round(2),
          adj_close: row['adjClose']&.to_f&.round(4),
          volume:    row['volume']&.to_i
        }
      end.sort_by { |p| p[:date] }
    rescue StandardError => e
      warn "[MarketDataService] FMP historical fetch failed for #{symbol}: #{e.message}" unless test_env?
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
        {
          date:   date,
          open:   vals['1. open']&.to_f&.round(2),
          high:   vals['2. high']&.to_f&.round(2),
          low:    vals['3. low']&.to_f&.round(2),
          close:  vals['4. close'].to_f.round(2),
          volume: vals['5. volume']&.to_i
        }
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
    
    # Returns the file path for a hierarchical cache entry
    def cache_file_path(type, symbol, period = nil)
      subdir = case type
               when 'quote'    then 'quotes'
               when 'analyst'  then 'analyst'
               when 'profile'  then 'profiles'
               when 'candle'   then 'historical'
               else                 'other'
               end
      
      dir = File.join(CACHE_DIR, subdir)
      FileUtils.mkdir_p(dir) unless test_env?
      
      filename = if period
                   "#{symbol}_#{period}.json"
                 else
                   "#{symbol}.json"
                 end
      
      File.join(dir, filename)
    end
    
    # Writes an individual cache entry to disk in hierarchical structure
    def write_cache_entry(type, symbol, data, period = nil)
      return if test_env?
      
      file_path = cache_file_path(type, symbol, period)
      payload = {
        'data' => serialize_value(data),
        'cached_at' => Time.now.iso8601
      }
      
      File.write(file_path, JSON.generate(payload))
    rescue StandardError => e
      warn "[MarketDataService] Failed to write cache entry to #{file_path}: #{e.message}"
    end
    
    # Reads an individual cache entry from disk
    def read_cache_entry(type, symbol, period = nil)
      file_path = cache_file_path(type, symbol, period)
      return nil unless File.exist?(file_path)
      
      # Check if file is expired (older than CACHE_TTL)
      return nil if cache_entry_expired?(file_path)
      
      payload = JSON.parse(File.read(file_path))
      deserialize_value_from_type(type, payload['data'])
    rescue StandardError => e
      warn "[MarketDataService] Failed to read cache entry from #{file_path}: #{e.message}" unless test_env?
      nil
    end
    
    # Checks if a cache file is expired based on file modification time
    def cache_entry_expired?(file_path)
      return true unless File.exist?(file_path)
      
      mtime = File.mtime(file_path)
      (Time.now - mtime) > CACHE_TTL
    end
    
    # Deletes an individual cache entry from disk
    def delete_cache_entry(type, symbol, period = nil)
      file_path = cache_file_path(type, symbol, period)
      File.delete(file_path) if File.exist?(file_path)
    rescue StandardError => e
      warn "[MarketDataService] Failed to delete cache entry at #{file_path}: #{e.message}" unless test_env?
    end
    
    # Serializes a value for JSON storage
    def serialize_value(value)
      case value
      when Array
        value.map { |item| item.is_a?(Hash) ? item.transform_keys(&:to_s) : item }
      when Hash
        value.transform_keys(&:to_s)
      else
        value
      end
    end
    
    # Deserializes a value based on its type
    def deserialize_value_from_type(type, value)
      case type
      when 'analyst', 'profile'
        value.is_a?(Hash) ? value.transform_keys(&:to_sym) : value
      when 'candle'
        value.is_a?(Array) ? value.map { |h| h.is_a?(Hash) ? h.transform_keys(&:to_sym) : h } : value
      else
        value  # quote data keeps string keys as-is
      end
    end

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
      # Try to load from monolithic cache files (current or legacy locations)
      source_file = if File.exist?(CACHE_FILE)
                      CACHE_FILE
                    elsif File.exist?(LEGACY_CACHE_FILE)
                      LEGACY_CACHE_FILE
                    elsif File.exist?(LEGACY_TMP_CACHE_FILE)
                      LEGACY_TMP_CACHE_FILE
                    else
                      nil
                    end

      if source_file
        payload    = JSON.parse(File.read(source_file))
        raw_cache  = payload['cache']      || {}
        raw_stamps = payload['timestamps'] || {}

        raw_cache.each do |k, v|
          @persistent_cache[k] = deserialize_value(k, v)
        end
        raw_stamps.each do |k, ts|
          @cache_timestamps[k] = ts ? Time.parse(ts) : nil
        end

        # One-time migration: write legacy cache into the new location.
        save_to_disk if source_file != CACHE_FILE
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

    # Parses a cache key into [type, symbol, period]
    def _parse_cache_key(key)
      if key.start_with?('analyst:')
        ['analyst', key.sub('analyst:', ''), nil]
      elsif key.start_with?('profile:')
        ['profile', key.sub('profile:', ''), nil]
      elsif key.start_with?('candle:')
        parts = key.split(':')  # ["candle", "SYMBOL", "PERIOD"]
        ['candle', parts[1], parts[2]]
      else
        ['quote', key, nil]
      end
    end

    # Load disk cache immediately at class load so data survives restarts.
    # Must be defined AFTER load_from_disk so it can call it.
    def _boot_load
      if File.exist?(CACHE_FILE)
        load_from_disk
        puts "[MarketDataService] Cache loaded from #{CACHE_FILE} (#{@persistent_cache.size} entries)"
      else
        puts "[MarketDataService] No disk cache found at #{CACHE_FILE} — starting with empty cache"
      end
    rescue StandardError => e
      warn "[MarketDataService] Failed to load disk cache at #{CACHE_FILE}: #{e.message}"
    end
  end

  _boot_load
end
