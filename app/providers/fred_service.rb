require_relative 'cache_store'
require_relative 'http_client'

module Providers
  # FRED (St. Louis Fed) — macroeconomic series.
  #
  # Free, unlimited with an API key. Used to supply the risk-free rate for
  # Black-Scholes (§2.3) and Sharpe ratio (§2.2), plus a macro context panel.
  #
  # Sign-up: https://fred.stlouisfed.org/docs/api/api_key.html
  # Env var: FRED_API_KEY
  module FredService
    BASE      = 'https://api.stlouisfed.org/fred'
    NAMESPACE = 'fred'
    CACHE_TTL = 24 * 3600  # 24 h — FRED series update at most daily
    THROTTLE  = Throttle.new(0.1) # token-bucket friendly floor

    # Commonly used series IDs
    SERIES = {
      treasury_3mo:    'DGS3MO',   # 3-Month Treasury Constant Maturity Rate
      treasury_2yr:    'DGS2',
      treasury_10yr:   'DGS10',    # 10-Year Treasury (benchmark)
      treasury_30yr:   'DGS30',
      fed_funds:       'DFF',      # Effective Federal Funds Rate
      cpi:             'CPIAUCSL', # CPI All Urban Consumers (monthly)
      unemployment:    'UNRATE',
      vix:             'VIXCLS'    # CBOE VIX close
    }.freeze

    module_function

    # Latest N observations for a named series (:treasury_10yr) or raw FRED id.
    # Returns an array of { date: 'YYYY-MM-DD', value: Float }.
    def observations(series, limit: 1)
      series_id = resolve(series)
      return nil unless series_id

      cache_key = "obs_#{series_id}_#{limit}"
      cached = CacheStore.read(NAMESPACE, cache_key, ttl: CACHE_TTL)
      return symbolize(cached) if cached

      data = request('/series/observations',
                     series_id:   series_id,
                     limit:       limit,
                     sort_order:  'desc',
                     file_type:   'json')
      return nil unless data.is_a?(Hash)

      rows = (data['observations'] || []).filter_map do |r|
        val = r['value']
        next if val.nil? || val == '.'
        { 'date' => r['date'], 'value' => val.to_f }
      end
      CacheStore.write(NAMESPACE, cache_key, rows)
      symbolize(rows)
    end

    # Risk-free rate as a decimal (e.g. 0.0432 for 4.32%). Defaults to 3-month
    # treasury which is the textbook Black-Scholes proxy.
    def risk_free_rate(term: :treasury_3mo)
      rows = observations(term, limit: 1)
      return nil unless rows.is_a?(Array) && !rows.empty?

      pct = rows.first[:value]
      pct.nil? ? nil : (pct / 100.0)
    end

    # One-shot macro snapshot for a dashboard panel. Returns:
    #   { fed_funds: {date:, value:}, treasury_10yr: {...}, cpi: {...}, ... }
    def macro_snapshot
      keys = %i[fed_funds treasury_3mo treasury_10yr cpi unemployment vix]
      keys.each_with_object({}) do |key, acc|
        row = observations(key, limit: 1)&.first
        acc[key] = row
      end
    end

    # Current yield curve snapshot across common maturities.
    def yield_curve
      %i[treasury_3mo treasury_2yr treasury_10yr treasury_30yr].each_with_object({}) do |key, acc|
        row = observations(key, limit: 1)&.first
        acc[key] = row
      end
    end

    # ---- Internals ----------------------------------------------------------

    def resolve(series)
      case series
      when Symbol then SERIES[series]
      when String then series
      end
    end

    def request(path, **params)
      api_key = ENV['FRED_API_KEY']
      unless api_key && !api_key.empty?
        warn '[FredService] FRED_API_KEY not set — skipping call' unless test_env?
        return nil
      end

      THROTTLE.wait!
      query = params.merge(api_key: api_key).map { |k, v| "#{k}=#{URI.encode_www_form_component(v.to_s)}" }.join('&')
      url   = "#{BASE}#{path}?#{query}"

      status, parsed, _body = HttpClient.get_json(url)
      unless status.between?(200, 299)
        warn "[FredService] HTTP #{status} for #{path}" unless test_env?
        return nil
      end
      parsed
    rescue StandardError => e
      warn "[FredService] request failed for #{path}: #{e.message}" unless test_env?
      nil
    end

    def symbolize(arr)
      return nil unless arr.is_a?(Array)
      arr.map { |h| h.is_a?(Hash) ? h.transform_keys(&:to_sym) : h }
    end

    def test_env?
      ENV['RACK_ENV'] == 'test'
    end
  end
end
