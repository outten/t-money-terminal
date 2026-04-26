module Analytics
  # Risk & performance statistics derived from a closes time series.
  #
  # Formulas follow textbook conventions:
  #   - Daily returns: (C_t / C_{t-1}) - 1
  #   - Annualised vol: stdev(daily_returns, ddof=1) × √252
  #   - Annualised return: (C_last / C_first)^(1/years) - 1, CAGR style
  #   - Sharpe: (annual_return - rf) / annual_vol
  #   - Sortino: (annual_return - rf) / downside deviation
  #   - Max drawdown: min over t of (C_t - peak_t) / peak_t
  #   - Historical VaR: the α-quantile of the return distribution
  #   - Parametric VaR: mean + z_α × stdev (assumes normality)
  #   - Beta: cov(asset, benchmark) / var(benchmark)
  module Risk
    TRADING_DAYS = 252

    module_function

    # Simple (arithmetic) daily returns.
    def returns(closes)
      return [] if closes.length < 2
      (1...closes.length).map { |i| closes[i] / closes[i - 1].to_f - 1.0 }
    end

    # Continuously compounded (log) daily returns.
    def log_returns(closes)
      return [] if closes.length < 2
      (1...closes.length).map { |i| Math.log(closes[i] / closes[i - 1].to_f) }
    end

    def annualized_return(closes, periods: TRADING_DAYS)
      return nil if closes.length < 2 || closes.first.zero?
      total = closes.last / closes.first.to_f
      years = (closes.length - 1).to_f / periods
      return nil if years.zero?
      total**(1.0 / years) - 1.0
    end

    def annualized_volatility(closes, periods: TRADING_DAYS)
      r = returns(closes)
      return nil if r.length < 2
      mean = r.sum / r.length
      var  = r.sum { |x| (x - mean)**2 } / (r.length - 1)
      Math.sqrt(var) * Math.sqrt(periods)
    end

    def sharpe(closes, risk_free_rate: 0.0, periods: TRADING_DAYS)
      ann_ret = annualized_return(closes, periods: periods)
      ann_vol = annualized_volatility(closes, periods: periods)
      return nil if ann_ret.nil? || ann_vol.nil? || ann_vol.zero?
      (ann_ret - risk_free_rate) / ann_vol
    end

    def sortino(closes, risk_free_rate: 0.0, periods: TRADING_DAYS)
      r = returns(closes)
      return nil if r.empty?
      target   = risk_free_rate / periods.to_f
      downside = r.map { |x| [target - x, 0].max }
      d_var    = downside.sum { |d| d**2 } / r.length.to_f
      d_dev    = Math.sqrt(d_var) * Math.sqrt(periods)
      ann_ret  = annualized_return(closes, periods: periods)
      return nil if d_dev.zero? || ann_ret.nil?
      (ann_ret - risk_free_rate) / d_dev
    end

    # Maximum drawdown as a negative decimal (e.g. -0.23 means peak-to-trough -23%).
    def max_drawdown(closes)
      return nil if closes.empty?
      peak = closes.first
      max_dd = 0.0
      closes.each do |c|
        peak = c if c > peak
        next if peak.zero?
        dd = (c - peak) / peak.to_f
        max_dd = dd if dd < max_dd
      end
      max_dd
    end

    # Historical Value-at-Risk: the α-quantile of the empirical return
    # distribution. For confidence 0.95 returns the 5th-percentile return
    # (a negative decimal if losses dominate the lower tail).
    def var_historical(closes, confidence: 0.95)
      r = returns(closes)
      return nil if r.empty?
      sorted = r.sort
      idx = ((1 - confidence) * sorted.length).floor
      idx = 0 if idx.negative?
      idx = sorted.length - 1 if idx >= sorted.length
      sorted[idx]
    end

    # Parametric VaR: assumes returns are normally distributed and uses the
    # inverse normal CDF for the quantile.
    def var_parametric(closes, confidence: 0.95)
      r = returns(closes)
      return nil if r.length < 2
      mean = r.sum / r.length
      var  = r.sum { |x| (x - mean)**2 } / (r.length - 1)
      sd   = Math.sqrt(var)
      z    = inverse_normal_cdf(1 - confidence)
      mean + z * sd
    end

    # Beta of an asset vs. a benchmark. Arrays are aligned tail-first so
    # callers can pass longer-than-needed series.
    def beta(asset_closes, benchmark_closes)
      ra = returns(asset_closes)
      rb = returns(benchmark_closes)
      n  = [ra.length, rb.length].min
      return nil if n < 2

      ra = ra.last(n); rb = rb.last(n)
      mean_a = ra.sum / n.to_f
      mean_b = rb.sum / n.to_f
      cov    = ra.each_with_index.sum { |a, i| (a - mean_a) * (rb[i] - mean_b) } / (n - 1).to_f
      var_b  = rb.sum { |b| (b - mean_b)**2 } / (n - 1).to_f
      return nil if var_b.zero?
      cov / var_b
    end

    # Build a square correlation matrix from a hash of {symbol => bars[]}.
    # `field: :adj_close` (the default) prefers dividend-adjusted closes —
    # correlation of total returns is the right interpretation for any holding
    # that pays dividends. Diagonal is 1.0; off-diagonal cells are computed
    # by aligning the two series on common dates.
    #
    # Returns:
    #   { symbols: [...sorted symbol order...],
    #     matrix:  [[Float|nil, ...], ...],     # nil when alignment yielded < 2 points
    #     period:  whatever was passed in }
    #
    # Order is the iteration order of `series_by_symbol` so callers can pass an
    # ordered hash to control axis labelling.
    def correlation_matrix(series_by_symbol, field: :adj_close)
      symbols = series_by_symbol.keys
      n       = symbols.length
      matrix  = Array.new(n) { Array.new(n) }

      symbols.each_with_index do |sym_a, i|
        bars_a = series_by_symbol[sym_a] || []
        symbols.each_with_index do |sym_b, j|
          if i == j
            matrix[i][j] = 1.0
            next
          end
          # Use the upper triangle to avoid recomputing the symmetric pair.
          if j < i
            matrix[i][j] = matrix[j][i]
            next
          end
          bars_b = series_by_symbol[sym_b] || []
          a, b   = align_on_dates(bars_a, bars_b, field: field)
          matrix[i][j] = a.length >= 2 ? correlation(a, b) : nil
        end
      end

      { symbols: symbols, matrix: matrix }
    end

    # Pearson correlation of daily returns (-1..1).
    def correlation(a, b)
      ra = returns(a); rb = returns(b)
      n  = [ra.length, rb.length].min
      return nil if n < 2

      ra = ra.last(n); rb = rb.last(n)
      mean_a = ra.sum / n.to_f
      mean_b = rb.sum / n.to_f
      cov    = ra.each_with_index.sum { |x, i| (x - mean_a) * (rb[i] - mean_b) } / (n - 1).to_f
      va     = ra.sum { |x| (x - mean_a)**2 } / (n - 1).to_f
      vb     = rb.sum { |y| (y - mean_b)**2 } / (n - 1).to_f
      denom  = Math.sqrt(va * vb)
      denom.zero? ? nil : cov / denom
    end

    # Align two {date, close, [adj_close]} series on common dates. Returns
    # [series_a_values, series_b_values] in chronological order containing only
    # dates present in both. When `field: :adj_close` is requested and a row
    # has it, it is preferred over the raw close (falls back to close otherwise).
    def align_on_dates(series_a, series_b, field: :close)
      return [[], []] unless series_a.is_a?(Array) && series_b.is_a?(Array)
      map_b = series_b.to_h { |p| [p[:date] || p['date'], pick_value(p, field)] }
      a_out = []
      b_out = []
      series_a.each do |p|
        d = p[:date] || p['date']
        next unless map_b.key?(d)
        a_out << pick_value(p, field).to_f
        b_out << map_b[d].to_f
      end
      [a_out, b_out]
    end

    # Extracts the chosen field (with adj_close→close fallback) from a bar.
    def pick_value(point, field)
      if field == :adj_close
        point[:adj_close] || point['adj_close'] || point[:close] || point['close']
      else
        point[:close] || point['close']
      end
    end

    # Convenience: returns a float array for a series of bars, preferring
    # adj_close when `total_return: true` and the bar has it.
    def closes_from(bars, total_return: false)
      field = total_return ? :adj_close : :close
      bars.map { |p| pick_value(p, field).to_f }
    end

    # Beasley-Springer-Moro rational approximation of the inverse standard
    # normal CDF. Accurate to ~1e-9 over the entire (0, 1) interval.
    def inverse_normal_cdf(p)
      raise ArgumentError, 'p must be in (0, 1)' if p <= 0 || p >= 1

      a = [-3.969683028665376e+01,  2.209460984245205e+02,
           -2.759285104469687e+02,  1.383577518672690e+02,
           -3.066479806614716e+01,  2.506628277459239e+00]
      b = [-5.447609879822406e+01,  1.615858368580409e+02,
           -1.556989798598866e+02,  6.680131188771972e+01,
           -1.328068155288572e+01]
      c = [-7.784894002430293e-03, -3.223964580411365e-01,
           -2.400758277161838e+00, -2.549732539343734e+00,
            4.374664141464968e+00,  2.938163982698783e+00]
      d = [ 7.784695709041462e-03,  3.224671290700398e-01,
            2.445134137142996e+00,  3.754408661907416e+00]

      p_low  = 0.02425
      p_high = 1 - p_low

      if p < p_low
        q = Math.sqrt(-2 * Math.log(p))
        (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
          ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
      elsif p <= p_high
        q = p - 0.5
        r = q * q
        (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q /
          (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)
      else
        q = Math.sqrt(-2 * Math.log(1 - p))
        -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
          ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
      end
    end
  end
end
