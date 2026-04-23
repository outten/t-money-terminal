require_relative 'cache_store'
require_relative 'http_client'

module Providers
  # Polygon.io — options chains, reference contracts, end-of-day snapshots.
  #
  # Free tier: 5 requests/minute → enforce 13 s between calls.
  # Options data on free tier is end-of-day delayed, which is fine for
  # Black-Scholes validation and IV surface visualisations.
  #
  # Sign-up: https://polygon.io/
  # Env var: POLYGON_API_KEY
  module PolygonService
    BASE      = 'https://api.polygon.io'
    NAMESPACE = 'polygon'
    CACHE_TTL = 3600             # 1 h — options data is end-of-day anyway
    THROTTLE  = Throttle.new(13) # 5 req/min → min 12 s; use 13 s for margin

    module_function

    # Reference: list of option contracts for an underlying, optionally filtered
    # by expiration date (YYYY-MM-DD). Returns an array of contract hashes.
    def contracts(symbol, expiration: nil, limit: 250)
      cache_key = "contracts_#{symbol.upcase}_#{expiration || 'all'}_#{limit}"
      cached = CacheStore.read(NAMESPACE, cache_key, ttl: CACHE_TTL)
      return cached if cached

      params = { underlying_ticker: symbol.upcase, limit: limit }
      params[:expiration_date] = expiration if expiration

      data = request('/v3/reference/options/contracts', **params)
      return nil unless data.is_a?(Hash)

      results = data['results'] || []
      CacheStore.write(NAMESPACE, cache_key, results)
      results
    end

    # Snapshot of the full options chain with greeks and implied volatility.
    # Free tier returns delayed data.
    def options_snapshot(symbol)
      cache_key = "snapshot_#{symbol.upcase}"
      cached = CacheStore.read(NAMESPACE, cache_key, ttl: CACHE_TTL)
      return cached if cached

      data = request("/v3/snapshot/options/#{symbol.upcase}", limit: 250)
      return nil unless data.is_a?(Hash)

      results = data['results'] || []
      CacheStore.write(NAMESPACE, cache_key, results)
      results
    end

    # Daily OHLCV aggregates for the underlying — useful for realised-vol inputs.
    # Mirrors the shape returned by MarketDataService#historical.
    def daily_aggregates(symbol, from:, to:)
      cache_key = "agg_#{symbol.upcase}_#{from}_#{to}"
      cached = CacheStore.read(NAMESPACE, cache_key, ttl: CACHE_TTL)
      return cached if cached

      path = "/v2/aggs/ticker/#{symbol.upcase}/range/1/day/#{from}/#{to}"
      data = request(path, adjusted: true, sort: 'asc', limit: 5000)
      return nil unless data.is_a?(Hash)

      results = (data['results'] || []).map do |bar|
        {
          'date'   => Time.at(bar['t'].to_i / 1000).utc.strftime('%Y-%m-%d'),
          'open'   => bar['o'],
          'high'   => bar['h'],
          'low'    => bar['l'],
          'close'  => bar['c'],
          'volume' => bar['v']
        }
      end
      CacheStore.write(NAMESPACE, cache_key, results)
      results
    end

    # ---- Internals ----------------------------------------------------------

    def request(path, **params)
      api_key = ENV['POLYGON_API_KEY']
      unless api_key && !api_key.empty?
        warn '[PolygonService] POLYGON_API_KEY not set — skipping call' unless test_env?
        return nil
      end

      THROTTLE.wait!
      query = params.merge(apiKey: api_key).map { |k, v| "#{k}=#{URI.encode_www_form_component(v.to_s)}" }.join('&')
      url   = "#{BASE}#{path}?#{query}"

      status, parsed, _body = HttpClient.get_json(url)

      if status == 429
        warn '[PolygonService] Rate limited (429)' unless test_env?
        return nil
      end
      unless status.between?(200, 299)
        warn "[PolygonService] HTTP #{status} for #{path}" unless test_env?
        return nil
      end

      # Polygon returns { status: "ERROR", error: "..." } on problems.
      if parsed.is_a?(Hash) && parsed['status'] == 'ERROR'
        warn "[PolygonService] API error: #{parsed['error']}" unless test_env?
        return nil
      end

      parsed
    rescue StandardError => e
      warn "[PolygonService] request failed for #{path}: #{e.message}" unless test_env?
      nil
    end

    def test_env?
      ENV['RACK_ENV'] == 'test'
    end
  end
end
