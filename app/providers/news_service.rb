require 'date'
require_relative 'cache_store'
require_relative 'http_client'

module Providers
  # Company-news aggregator.
  #
  # Primary: Finnhub /company-news (uses existing FINNHUB_API_KEY, 60 req/min).
  # Fallback: NewsAPI.org /v2/everything (100 req/day free).
  #
  # Env vars: FINNHUB_API_KEY (primary), NEWSAPI_KEY (fallback).
  module NewsService
    NAMESPACE = 'news'
    CACHE_TTL = 3600 # 1 h

    FINNHUB_BASE  = 'https://finnhub.io/api/v1'
    NEWSAPI_BASE  = 'https://newsapi.org/v2'

    FINNHUB_THROTTLE = Throttle.new(2)   # 60 req/min → 1 s; add margin
    NEWSAPI_THROTTLE = Throttle.new(1)

    module_function

    # Returns a normalized array of articles sorted newest-first:
    #   [{ headline:, summary:, url:, source:, datetime: ISO8601, image: }]
    def company_news(symbol, days: 7, limit: 25)
      cache_key = "#{symbol.upcase}_#{days}"
      cached = CacheStore.read(NAMESPACE, cache_key, ttl: CACHE_TTL)
      return symbolize(cached).first(limit) if cached

      articles = fetch_finnhub(symbol, days) || fetch_newsapi(symbol, days)
      return nil if articles.nil? || articles.empty?

      CacheStore.write(NAMESPACE, cache_key, articles)
      symbolize(articles).first(limit)
    end

    # ---- Providers ----------------------------------------------------------

    def fetch_finnhub(symbol, days)
      api_key = ENV['FINNHUB_API_KEY']
      return nil unless api_key && !api_key.empty?

      FINNHUB_THROTTLE.wait!
      from = (Date.today - days).to_s
      to   = Date.today.to_s
      url  = "#{FINNHUB_BASE}/company-news?symbol=#{URI.encode_www_form_component(symbol.upcase)}" \
             "&from=#{from}&to=#{to}&token=#{api_key}"

      status, parsed, _body = HttpClient.get_json(url)
      return nil unless status.between?(200, 299) && parsed.is_a?(Array)

      parsed.filter_map do |row|
        next unless row['headline'] && row['url']
        {
          'headline' => row['headline'],
          'summary'  => row['summary'],
          'url'      => row['url'],
          'source'   => row['source'],
          'datetime' => row['datetime'] ? Time.at(row['datetime']).utc.iso8601 : nil,
          'image'    => row['image']
        }
      end.sort_by { |a| a['datetime'].to_s }.reverse
    rescue StandardError => e
      warn "[NewsService] Finnhub news failed for #{symbol}: #{e.message}" unless test_env?
      nil
    end

    def fetch_newsapi(symbol, days)
      api_key = ENV['NEWSAPI_KEY']
      return nil unless api_key && !api_key.empty?

      NEWSAPI_THROTTLE.wait!
      from = (Date.today - days).to_s
      url  = "#{NEWSAPI_BASE}/everything?q=#{URI.encode_www_form_component(symbol)}" \
             "&from=#{from}&sortBy=publishedAt&pageSize=50&language=en" \
             "&apiKey=#{api_key}"

      status, parsed, _body = HttpClient.get_json(url)
      return nil unless status.between?(200, 299) && parsed.is_a?(Hash)
      return nil unless parsed['status'] == 'ok'

      (parsed['articles'] || []).filter_map do |row|
        next unless row['title'] && row['url']
        {
          'headline' => row['title'],
          'summary'  => row['description'],
          'url'      => row['url'],
          'source'   => row.dig('source', 'name'),
          'datetime' => row['publishedAt'],
          'image'    => row['urlToImage']
        }
      end
    rescue StandardError => e
      warn "[NewsService] NewsAPI failed for #{symbol}: #{e.message}" unless test_env?
      nil
    end

    def symbolize(arr)
      return [] unless arr.is_a?(Array)
      arr.map { |h| h.is_a?(Hash) ? h.transform_keys(&:to_sym) : h }
    end

    def test_env?
      ENV['RACK_ENV'] == 'test'
    end
  end
end
