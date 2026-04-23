require_relative 'cache_store'
require_relative 'http_client'

module Providers
  # Stooq — international indices via public CSV endpoints. No API key.
  #
  # Currently used to surface actual local index levels on the Japan and
  # Europe region pages (which today proxy through US-listed ETFs).
  module StooqService
    BASE      = 'https://stooq.com/q/l/'
    NAMESPACE = 'stooq'
    CACHE_TTL = 3600
    THROTTLE  = Throttle.new(1)

    # Mapping of friendly names → Stooq index tickers.
    INDICES = {
      nikkei:    '^nkx',   # Nikkei 225
      topix:     '^tpx',   # TOPIX
      dax:       '^dax',   # DAX
      ftse:      '^ukx',   # FTSE 100
      cac:       '^cac',   # CAC 40
      stoxx:     '^stoxx', # STOXX Europe 600
      hang_seng: '^hsi',
      sp500:     '^spx',
      nasdaq:    '^ndq',
      dow:       '^dji'
    }.freeze

    module_function

    # Returns the latest end-of-day bar for an index:
    #   { symbol:, name:, date:, open:, high:, low:, close:, volume: }
    def index(name)
      ticker = INDICES[name]
      return nil unless ticker

      cache_key = name.to_s
      cached = CacheStore.read(NAMESPACE, cache_key, ttl: CACHE_TTL)
      return symbolize(cached) if cached

      THROTTLE.wait!
      url = "#{BASE}?s=#{URI.encode_www_form_component(ticker)}&f=sd2t2ohlcv&h&e=csv"
      status, body = HttpClient.get_text(url)
      return nil unless status.between?(200, 299) && body && !body.empty?

      parsed = parse_csv(body)
      return nil unless parsed

      parsed['name'] = name.to_s
      CacheStore.write(NAMESPACE, cache_key, parsed)
      symbolize(parsed)
    rescue StandardError => e
      warn "[StooqService] fetch failed for #{name}: #{e.message}" unless test_env?
      nil
    end

    # ---- Internals ----------------------------------------------------------

    # Stooq returns CSV like:
    #   Symbol,Date,Time,Open,High,Low,Close,Volume
    #   ^NKX,2026-04-23,08:30:00,37500.00,37820.00,37480.00,37780.00,0
    def parse_csv(body)
      lines = body.strip.split(/\r?\n/)
      return nil if lines.length < 2

      headers = lines[0].split(',').map { |h| h.downcase.strip }
      values  = lines[1].split(',').map(&:strip)
      return nil if values.first.to_s.upcase == 'N/D' # Stooq "no data" sentinel

      row = headers.zip(values).to_h
      {
        'symbol' => row['symbol'],
        'date'   => row['date'],
        'time'   => row['time'],
        'open'   => row['open']&.to_f,
        'high'   => row['high']&.to_f,
        'low'    => row['low']&.to_f,
        'close'  => row['close']&.to_f,
        'volume' => row['volume']&.to_i
      }
    end

    def symbolize(h)
      h.is_a?(Hash) ? h.transform_keys(&:to_sym) : h
    end

    def test_env?
      ENV['RACK_ENV'] == 'test'
    end
  end
end
