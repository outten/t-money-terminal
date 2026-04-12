require_relative 'market_data_service'

class RecommendationService
  ALL_SYMBOLS = %w[SPY AAPL MSFT EWJ VGK].freeze

  REGION_MAP = {
    'SPY' => 'US', 'AAPL' => 'US', 'MSFT' => 'US',
    'EWJ' => 'Japan', 'VGK' => 'Europe'
  }.freeze

  def self.signal_for(symbol)
    signal_detail(symbol)[:signal]
  rescue StandardError
    'HOLD'
  end

  def self.signal_detail(symbol)
    analyst = MarketDataService.analyst_recommendations(symbol)
    if analyst && analyst_has_data?(analyst)
      signal = analyst_signal(analyst)
      { signal: signal, signal_type: 'Analyst Consensus', analyst: analyst }
    else
      data   = MarketDataService.quote(symbol)
      change = (data['10. change percent'] || data[:change] || '0%').to_f
      signal = change > 1.0 ? 'BUY' : change < -1.0 ? 'SELL' : 'HOLD'
      { signal: signal, signal_type: 'Momentum Signal', analyst: nil }
    end
  rescue StandardError
    { signal: 'HOLD', signal_type: 'Momentum Signal', analyst: nil }
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

  private_class_method def self.analyst_signal(analyst)
    bull = analyst[:strong_buy].to_i + analyst[:buy].to_i
    bear = analyst[:strong_sell].to_i + analyst[:sell].to_i
    hold = analyst[:hold].to_i
    if bull > bear + (hold / 2.0)
      'BUY'
    elsif bear > bull + (hold / 2.0)
      'SELL'
    else
      'HOLD'
    end
  end
end
