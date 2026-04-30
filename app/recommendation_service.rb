require_relative 'market_data_service'

class RecommendationService
  ALL_SYMBOLS = (MarketDataService::REGIONS.values.flatten).freeze

  REGION_MAP = ALL_SYMBOLS.each_with_object({}) do |sym, map|
    region_key = MarketDataService::REGIONS.find { |_k, v| v.include?(sym) }&.first
    map[sym] = MarketDataService::REGION_LABEL[region_key] if region_key
  end.freeze

  BUY_THRESHOLD  =  0.5
  SELL_THRESHOLD = -0.5

  # `cached_only: true` makes this a strictly cache-only read — never fires
  # a Finnhub request for analyst data and never reaches a live provider for
  # the quote fallback (relies on whatever's already in the in-memory cache).
  # Use on hot paths like /portfolio where N rows × N network calls would
  # blow up page-render time.
  def self.signal_for(symbol, cached_only: false)
    signal_detail(symbol, cached_only: cached_only)[:signal]
  rescue StandardError
    'HOLD'
  end

  def self.signal_detail(symbol, cached_only: false)
    analyst = cached_only \
      ? MarketDataService.analyst_cached(symbol) \
      : MarketDataService.analyst_recommendations(symbol)

    if analyst && analyst_has_data?(analyst)
      score  = analyst_score(analyst)
      signal = score_to_signal(score)
      { signal: signal, signal_type: 'Analyst Consensus', analyst: analyst, score: score.round(3) }
    else
      data   = cached_only \
        ? (MarketDataService.quote_cached(symbol) || {}) \
        : MarketDataService.quote(symbol)
      change = (data['10. change percent'] || data[:change] || '0%').to_f
      signal = change > 1.0 ? 'BUY' : change < -1.0 ? 'SELL' : 'HOLD'
      { signal: signal, signal_type: 'Momentum Signal', analyst: nil, score: nil }
    end
  rescue StandardError
    { signal: 'HOLD', signal_type: 'Momentum Signal', analyst: nil, score: nil }
  end

  def self.signals
    ALL_SYMBOLS.map do |symbol|
      data   = MarketDataService.quote(symbol)
      price  = data['05. price']          || data[:price]  || 'N/A'
      change = data['10. change percent'] || data[:change] || '0%'
      detail = signal_detail(symbol)
      {
        symbol:      symbol,
        region:      REGION_MAP[symbol],
        price:       price,
        change:      change,
        signal:      detail[:signal],
        signal_type: detail[:signal_type],
        analyst:     detail[:analyst],
        rationale:   rationale_for(detail[:signal], change, detail[:signal_type])
      }
    end
  end

  def self.rationale_for(signal, change, signal_type = 'Momentum Signal')
    if signal_type == 'Analyst Consensus'
      case signal
      when 'BUY'  then 'Wall Street analysts are net bullish on this symbol.'
      when 'SELL' then 'Wall Street analysts are net bearish on this symbol.'
      else             'Wall Street analysts are broadly neutral on this symbol.'
      end
    else
      case signal
      when 'BUY'  then "Price up #{change} — momentum suggests upward trend."
      when 'SELL' then "Price down #{change} — momentum suggests downward pressure."
      else             "Price change #{change} — within normal range, no clear trend."
      end
    end
  end

  private_class_method def self.analyst_has_data?(analyst)
    return false unless analyst
    (analyst[:strong_buy].to_i + analyst[:buy].to_i +
     analyst[:hold].to_i + analyst[:sell].to_i + analyst[:strong_sell].to_i) > 0
  end

  private_class_method def self.analyst_score(analyst)
    total = analyst[:strong_buy].to_i + analyst[:buy].to_i + analyst[:hold].to_i +
            analyst[:sell].to_i + analyst[:strong_sell].to_i
    return 0.0 if total.zero?

    ( analyst[:strong_buy].to_i   * 2 +
      analyst[:buy].to_i          * 1 +
      analyst[:hold].to_i         * 0 +
      analyst[:sell].to_i         * -1 +
      analyst[:strong_sell].to_i  * -2
    ).to_f / total
  end

  private_class_method def self.score_to_signal(score)
    if score > BUY_THRESHOLD
      'BUY'
    elsif score < SELL_THRESHOLD
      'SELL'
    else
      'HOLD'
    end
  end
end
