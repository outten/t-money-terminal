require_relative 'cache_store'
require_relative 'http_client'

module Providers
  # Financial Modeling Prep (FMP) — fundamentals, ratios, DCF, earnings calendar.
  #
  # Free tier: 250 requests/day. Fundamentals change slowly, so cache aggressively
  # (24 h TTL) and pre-warm via the refresh script.
  #
  # As of 2026, FMP's free tier uses the /stable/ API with the symbol passed as
  # a query parameter. The legacy /api/v3/ endpoints return 403 on free keys.
  #
  # Sign-up: https://site.financialmodelingprep.com/developer/docs
  # Env var: FMP_API_KEY
  module FmpService
    BASE           = 'https://financialmodelingprep.com/stable'
    NAMESPACE      = 'fmp'
    CACHE_TTL      = 24 * 3600      # 24 h — fundamentals update slowly
    EARNINGS_TTL   = 6 * 3600       # 6 h — calendar shifts within day
    THROTTLE       = Throttle.new(0.5) # 0.5s polite floor; 250/day is the real cap

    module_function

    # ---- Public API ---------------------------------------------------------

    def income_statement(symbol, limit: 5)
      fetch_statement(symbol, 'income-statement', limit: limit)
    end

    def balance_sheet(symbol, limit: 5)
      fetch_statement(symbol, 'balance-sheet-statement', limit: limit)
    end

    def cash_flow(symbol, limit: 5)
      fetch_statement(symbol, 'cash-flow-statement', limit: limit)
    end

    # Key per-share metrics: P/E, P/B, ROE, debt/equity, FCF yield, etc.
    def key_metrics(symbol, limit: 1)
      cache_key = "key_metrics_#{symbol.upcase}_#{limit}"
      cached = CacheStore.read(NAMESPACE, cache_key, ttl: CACHE_TTL)
      return symbolize(cached) if cached

      data = request('/key-metrics', symbol: symbol.upcase, limit: limit)
      return nil unless data.is_a?(Array) && !data.empty?

      CacheStore.write(NAMESPACE, cache_key, data)
      symbolize(data)
    end

    def ratios(symbol, limit: 1)
      cache_key = "ratios_#{symbol.upcase}_#{limit}"
      cached = CacheStore.read(NAMESPACE, cache_key, ttl: CACHE_TTL)
      return symbolize(cached) if cached

      data = request('/ratios', symbol: symbol.upcase, limit: limit)
      return nil unless data.is_a?(Array) && !data.empty?

      CacheStore.write(NAMESPACE, cache_key, data)
      symbolize(data)
    end

    # FMP's built-in DCF valuation. Returns { date:, symbol:, dcf:, price: }
    def dcf(symbol)
      cache_key = "dcf_#{symbol.upcase}"
      cached = CacheStore.read(NAMESPACE, cache_key, ttl: CACHE_TTL)
      return symbolize(cached).first if cached.is_a?(Array) && !cached.empty?
      return symbolize_one(cached) if cached.is_a?(Hash)

      data = request('/discounted-cash-flow', symbol: symbol.upcase)
      return nil unless data

      first = data.is_a?(Array) ? data.first : data
      return nil unless first.is_a?(Hash)

      CacheStore.write(NAMESPACE, cache_key, first)
      symbolize_one(first)
    end

    # Next upcoming earnings row for a symbol (or nil if none in window).
    #
    # On the free tier, the per-symbol /earnings endpoint is paywalled (402),
    # but /earnings-calendar is open and returns the full cross-company
    # calendar — so we fetch the calendar once (cached ~6 h), filter in Ruby,
    # and reuse it for every subsequent symbol lookup.
    def next_earnings(symbol, days_ahead: 120)
      sym = symbol.upcase

      per_symbol_key = "earnings_#{sym}"
      cached = CacheStore.read(NAMESPACE, per_symbol_key, ttl: EARNINGS_TTL)
      return symbolize_one(cached) if cached.is_a?(Hash)

      calendar = earnings_calendar(days_ahead: days_ahead)
      return nil unless calendar.is_a?(Array) && !calendar.empty?

      today = Date.today
      match = calendar.filter_map do |row|
        next unless row['symbol']&.upcase == sym
        date = row['date'] && (Date.parse(row['date']) rescue nil)
        next unless date && date >= today
        [date, row]
      end.sort_by(&:first).first&.last

      return nil unless match

      CacheStore.write(NAMESPACE, per_symbol_key, match)
      symbolize_one(match)
    end

    # Full earnings calendar for a date window. Cached ~6 h — one API call
    # populates next_earnings for every symbol in the portfolio.
    def earnings_calendar(days_ahead: 120)
      from = Date.today
      to   = Date.today + days_ahead
      cache_key = "earnings-calendar_#{from}_#{to}"

      cached = CacheStore.read(NAMESPACE, cache_key, ttl: EARNINGS_TTL)
      return cached if cached

      data = request('/earnings-calendar', from: from.to_s, to: to.to_s)
      return nil unless data.is_a?(Array)

      CacheStore.write(NAMESPACE, cache_key, data)
      data
    end

    # ---- Internals ----------------------------------------------------------

    def fetch_statement(symbol, kind, limit:)
      cache_key = "#{kind}_#{symbol.upcase}_#{limit}"
      cached = CacheStore.read(NAMESPACE, cache_key, ttl: CACHE_TTL)
      return symbolize(cached) if cached

      data = request("/#{kind}", symbol: symbol.upcase, limit: limit)
      return nil unless data.is_a?(Array) && !data.empty?

      CacheStore.write(NAMESPACE, cache_key, data)
      symbolize(data)
    end

    def request(path, **params)
      api_key = ENV['FMP_API_KEY']
      unless api_key && !api_key.empty?
        warn '[FmpService] FMP_API_KEY not set — skipping call' unless test_env?
        return nil
      end

      THROTTLE.wait!
      query = params.merge(apikey: api_key).map { |k, v| "#{k}=#{URI.encode_www_form_component(v)}" }.join('&')
      url   = "#{BASE}#{path}?#{query}"

      status, parsed, body = HttpClient.get_json(url, provider: 'fmp')

      if status == 429
        warn '[FmpService] Rate limited (429)' unless test_env?
        return nil
      end
      unless status.between?(200, 299)
        warn "[FmpService] HTTP #{status} for #{path}" unless test_env?
        return nil
      end

      # FMP returns { "Error Message" => "..." } on auth/limit errors.
      if parsed.is_a?(Hash) && parsed['Error Message']
        warn "[FmpService] API error: #{parsed['Error Message']}" unless test_env?
        return nil
      end

      parsed
    rescue StandardError => e
      warn "[FmpService] request failed for #{path}: #{e.message}" unless test_env?
      nil
    end

    def symbolize(arr)
      return nil unless arr.is_a?(Array)
      arr.map { |h| symbolize_one(h) }
    end

    def symbolize_one(h)
      return h unless h.is_a?(Hash)
      h.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
    end

    def test_env?
      ENV['RACK_ENV'] == 'test'
    end
  end
end
