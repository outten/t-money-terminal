module Analytics
  # Classic technical indicators computed from a closes-only time series.
  #
  # Conventions:
  # - Input arrays are oldest → newest.
  # - Outputs are arrays the same length as input, with leading `nil`s for
  #   bars that don't yet have enough history to compute a value.
  # - All pure Ruby, zero API calls. Safe to call on every page render.
  module Indicators
    module_function

    # Simple Moving Average — rolling arithmetic mean over `period` bars.
    def sma(values, period)
      raise ArgumentError, 'period must be positive' if period <= 0
      return Array.new(values.length) if values.length < period

      result = Array.new(period - 1)
      window_sum = values.first(period).sum.to_f
      result << window_sum / period
      (period...values.length).each do |i|
        window_sum += values[i] - values[i - period]
        result << window_sum / period
      end
      result
    end

    # Exponential Moving Average — seeds the first value from an SMA of the
    # initial `period` bars, then decays with k = 2 / (period + 1).
    def ema(values, period)
      raise ArgumentError, 'period must be positive' if period <= 0
      return Array.new(values.length) if values.length < period

      k = 2.0 / (period + 1)
      result = Array.new(period - 1)
      seed = values.first(period).sum.to_f / period
      result << seed
      (period...values.length).each do |i|
        result << values[i] * k + result.last * (1 - k)
      end
      result
    end

    # MACD line = EMA(fast) - EMA(slow); signal = EMA of MACD; histogram = MACD - signal.
    def macd(values, fast: 12, slow: 26, signal: 9)
      fast_ema = ema(values, fast)
      slow_ema = ema(values, slow)
      macd_line = fast_ema.zip(slow_ema).map { |f, s| f && s ? f - s : nil }

      first_valid = macd_line.index { |v| !v.nil? }
      signal_line = Array.new(values.length)
      histogram   = Array.new(values.length)
      return { macd: macd_line, signal: signal_line, histogram: histogram } if first_valid.nil?

      macd_tail = macd_line[first_valid..]
      sig_tail  = ema(macd_tail, signal)
      sig_tail.each_with_index do |s, i|
        idx = first_valid + i
        signal_line[idx] = s
        histogram[idx]   = s && macd_line[idx] ? macd_line[idx] - s : nil
      end

      { macd: macd_line, signal: signal_line, histogram: histogram }
    end

    # Wilder's Relative Strength Index. Returns values in 0..100.
    def rsi(values, period: 14)
      return Array.new(values.length) if values.length < period + 1

      gains  = Array.new(values.length - 1)
      losses = Array.new(values.length - 1)
      (1...values.length).each do |i|
        diff = values[i] - values[i - 1]
        gains[i - 1]  = [diff, 0].max
        losses[i - 1] = [-diff, 0].max
      end

      avg_gain = gains.first(period).sum.to_f / period
      avg_loss = losses.first(period).sum.to_f / period

      result = Array.new(period) # leading nils for bars without a full window
      result << rsi_value(avg_gain, avg_loss)

      (period...gains.length).each do |i|
        avg_gain = (avg_gain * (period - 1) + gains[i]) / period
        avg_loss = (avg_loss * (period - 1) + losses[i]) / period
        result << rsi_value(avg_gain, avg_loss)
      end
      result
    end

    # Bollinger Bands — middle line is SMA, upper/lower are ±stddev × rolling σ.
    def bollinger(values, period: 20, stddev: 2)
      middle = sma(values, period)
      upper  = Array.new(values.length)
      lower  = Array.new(values.length)

      (period - 1...values.length).each do |i|
        window = values[i - period + 1..i]
        mean   = middle[i]
        var    = window.sum { |x| (x - mean)**2 } / period.to_f
        sd     = Math.sqrt(var)
        upper[i] = mean + stddev * sd
        lower[i] = mean - stddev * sd
      end
      { upper: upper, middle: middle, lower: lower }
    end

    # Convenience: latest non-nil value from an indicator array.
    def latest(series)
      series.reverse.find { |v| !v.nil? }
    end

    # --- internals -----------------------------------------------------------

    def rsi_value(avg_gain, avg_loss)
      return 100.0 if avg_loss.zero? && avg_gain.positive?
      return 50.0  if avg_gain.zero? && avg_loss.zero?
      rs = avg_gain / avg_loss
      100.0 - 100.0 / (1.0 + rs)
    end
  end
end
