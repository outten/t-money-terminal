require_relative 'market_data_service'

class RecommendationService
  ALL_SYMBOLS = %w[SPY AAPL MSFT EWJ VGK].freeze

  REGION_MAP = {
    'SPY' => 'US', 'AAPL' => 'US', 'MSFT' => 'US',
    'EWJ' => 'Japan', 'VGK' => 'Europe'
  }.freeze

  # Simple rule-based signal using price change percent
  # In a real system this would use SMA crossover + RSI from time series data.
  def self.signal_for(symbol)
    data   = MarketDataService.quote(symbol)
    change = (data['10. change percent'] || data[:change] || '0%').to_f
    if change > 1.0
      'BUY'
    elsif change < -1.0
      'SELL'
    else
      'HOLD'
    end
  rescue StandardError
    'HOLD'
  end

  def self.signals
    ALL_SYMBOLS.map do |symbol|
      data   = MarketDataService.quote(symbol)
      price  = data['05. price']          || data[:price]  || 'N/A'
      change = data['10. change percent'] || data[:change] || '0%'
      signal = signal_for(symbol)
      rationale = rationale_for(signal, change)
      { symbol: symbol, region: REGION_MAP[symbol], price: price, signal: signal, rationale: rationale }
    end
  end

  def self.rationale_for(signal, change)
    case signal
    when 'BUY'  then "Price up #{change} — momentum suggests upward trend."
    when 'SELL' then "Price down #{change} — momentum suggests downward pressure."
    else             "Price change #{change} — within normal range, no clear trend."
    end
  end
end
