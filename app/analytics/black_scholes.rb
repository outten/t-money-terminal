module Analytics
  # Black-Scholes-Merton European option pricing + Greeks + implied vol.
  #
  # All rates/yields/vols are decimals (5% = 0.05). Time is in years.
  # Continuous dividend yield `q` is supported so the same module prices
  # equities, ETFs (yield > 0), and non-dividend assets (q = 0).
  #
  # Normal CDF uses Math.erf; implied vol uses bisection on the price
  # function — robust across deep-ITM / deep-OTM strikes where
  # Newton-Raphson tends to overshoot.
  module BlackScholes
    module_function

    # Standard normal CDF.
    def norm_cdf(x)
      0.5 * (1.0 + Math.erf(x / Math.sqrt(2.0)))
    end

    # Standard normal PDF.
    def norm_pdf(x)
      Math.exp(-0.5 * x * x) / Math.sqrt(2 * Math::PI)
    end

    # European option price.
    #   type: :call or :put
    #   s: spot price
    #   k: strike
    #   t: time to expiry in years
    #   r: risk-free rate (decimal, continuously compounded)
    #   sigma: volatility (decimal, annualised)
    #   q: continuous dividend yield (decimal, default 0)
    def price(type, s:, k:, t:, r:, sigma:, q: 0.0)
      return nil if t <= 0 || sigma <= 0 || s <= 0 || k <= 0

      sqrt_t = Math.sqrt(t)
      d1 = (Math.log(s / k.to_f) + (r - q + 0.5 * sigma * sigma) * t) / (sigma * sqrt_t)
      d2 = d1 - sigma * sqrt_t

      case type
      when :call
        s * Math.exp(-q * t) * norm_cdf(d1) - k * Math.exp(-r * t) * norm_cdf(d2)
      when :put
        k * Math.exp(-r * t) * norm_cdf(-d2) - s * Math.exp(-q * t) * norm_cdf(-d1)
      else
        raise ArgumentError, 'type must be :call or :put'
      end
    end

    # Greeks for a European option. Returns a hash:
    #   delta  — ∂V/∂S              (unitless)
    #   gamma  — ∂²V/∂S²            (per $ of spot²)
    #   vega   — ∂V/∂σ per 1% vol   (scaled /100)
    #   theta  — ∂V/∂t per calendar day (scaled /365)
    #   rho    — ∂V/∂r per 1% rate  (scaled /100)
    def greeks(type, s:, k:, t:, r:, sigma:, q: 0.0)
      return {} if t <= 0 || sigma <= 0 || s <= 0 || k <= 0

      sqrt_t = Math.sqrt(t)
      d1 = (Math.log(s / k.to_f) + (r - q + 0.5 * sigma * sigma) * t) / (sigma * sqrt_t)
      d2 = d1 - sigma * sqrt_t
      pdf_d1 = norm_pdf(d1)
      disc_q = Math.exp(-q * t)
      disc_r = Math.exp(-r * t)

      delta = case type
              when :call then disc_q * norm_cdf(d1)
              when :put  then disc_q * (norm_cdf(d1) - 1.0)
              else raise ArgumentError, 'type must be :call or :put'
              end

      gamma = disc_q * pdf_d1 / (s * sigma * sqrt_t)
      vega  = s * disc_q * pdf_d1 * sqrt_t / 100.0

      theta_raw =
        case type
        when :call
          (-s * disc_q * pdf_d1 * sigma / (2 * sqrt_t)) -
            r * k * disc_r * norm_cdf(d2) +
            q * s * disc_q * norm_cdf(d1)
        when :put
          (-s * disc_q * pdf_d1 * sigma / (2 * sqrt_t)) +
            r * k * disc_r * norm_cdf(-d2) -
            q * s * disc_q * norm_cdf(-d1)
        end
      theta = theta_raw / 365.0

      rho = case type
            when :call then  k * t * disc_r * norm_cdf(d2)  / 100.0
            when :put  then -k * t * disc_r * norm_cdf(-d2) / 100.0
            end

      { delta: delta, gamma: gamma, vega: vega, theta: theta, rho: rho }
    end

    # Implied volatility via bisection. Returns nil if no solution can be
    # found within the search bracket (typically means the market price
    # violates no-arbitrage bounds).
    def implied_volatility(type, market_price:, s:, k:, t:, r:, q: 0.0,
                           tol: 1e-6, max_iter: 200)
      return nil if market_price <= 0 || t <= 0 || s <= 0 || k <= 0

      low  = 1e-6
      high = 5.0
      max_iter.times do
        mid = (low + high) / 2.0
        p   = price(type, s: s, k: k, t: t, r: r, sigma: mid, q: q)
        return nil if p.nil?

        diff = p - market_price
        return mid if diff.abs < tol

        if diff > 0
          high = mid
        else
          low = mid
        end
        return mid if (high - low) < tol
      end

      (low + high) / 2.0
    end

    # Annualised historical (realised) volatility from a closes series,
    # using log returns. Useful for seeding Black-Scholes when no implied
    # vol is available. `periods` defaults to 252 trading days.
    def historical_volatility(closes, periods: 252)
      return nil if closes.length < 2
      rets = (1...closes.length).map { |i| Math.log(closes[i] / closes[i - 1].to_f) }
      mean = rets.sum / rets.length
      var  = rets.sum { |x| (x - mean)**2 } / (rets.length - 1)
      Math.sqrt(var) * Math.sqrt(periods)
    end
  end
end
