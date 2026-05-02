require 'date'

# RetirementProjection — combines ProfileStore (current_age, retirement_age,
# retirement_target_value) with the user's current portfolio value to
# answer one question: what annual return do I need from now to
# retirement to hit the target?
#
# Pure math, no I/O. Returns nil for any field that requires inputs the
# caller hasn't supplied yet — the view hides the whole section unless
# both age + target are configured.
#
# Verdict thresholds are anchored to long-run nominal CAGRs published in
# the references below. The cite block is rendered alongside the verdict
# in the view so the user sees the sources we're benchmarking against.
module RetirementProjection
  # Long-run nominal CAGRs from the cited datasets (1928–2023 window for
  # Damodaran). We pin specific numbers here so the verdict thresholds
  # have a defensible anchor and the view can show "X% vs the Y% historical
  # average."
  HISTORICAL_BENCHMARKS = [
    { label: 'S&P 500 (1928–2023, nominal CAGR)',           return: 0.099, source: 'damodaran' },
    { label: '10-year US Treasury (1928–2023, nominal CAGR)', return: 0.049, source: 'damodaran' },
    { label: '60/40 stock/bond portfolio (long-run, nominal)', return: 0.080, source: 'bogleheads' }
  ].freeze

  CITATIONS = [
    {
      key:   'damodaran',
      label: 'NYU Stern, Aswath Damodaran — Historical returns on stocks, bonds & bills (1928–2023)',
      url:   'https://pages.stern.nyu.edu/~adamodar/New_Home_Page/datafile/histretSP.html'
    },
    {
      key:   'bogleheads',
      label: 'Bogleheads wiki — Historical and expected returns of asset classes',
      url:   'https://www.bogleheads.org/wiki/Historical_and_expected_returns'
    },
    {
      key:   'fred_pcepi',
      label: 'Federal Reserve Bank of St. Louis (FRED) — PCE Price Index (long-run inflation reference)',
      url:   'https://fred.stlouisfed.org/series/PCEPI'
    },
    {
      key:   'bogleheads_swr',
      label: 'Bogleheads wiki — Safe withdrawal rates (Trinity study summary, 4% rule)',
      url:   'https://www.bogleheads.org/wiki/Safe_withdrawal_rates'
    }
  ].freeze

  module_function

  # Required CAGR to grow `current_value` to `target_value` in
  # `years` years.  Returns nil if any input is missing or non-positive,
  # or if years <= 0.
  def required_annual_return(current_value:, target_value:, years:)
    return nil if current_value.nil? || target_value.nil? || years.nil?
    cv = current_value.to_f
    tv = target_value.to_f
    y  = years.to_f
    return nil if cv <= 0 || tv <= 0 || y <= 0
    return 0.0 if tv <= cv  # Already at or past goal; no growth required.
    ((tv / cv) ** (1.0 / y) - 1.0).round(6)
  end

  # Full projection bundle for the /portfolio retirement-progress card.
  # Returns nil unless we have:
  #   - profile[:current_age], profile[:retirement_age]
  #   - profile[:retirement_target_value]
  #   - current_value > 0
  #
  # The user's `retirement_target_value` is interpreted as **real / today's
  # dollars** — the natural way to think about a goal ("I want $X of
  # purchasing power"). We compute BOTH:
  #
  #   real_required_return    — CAGR needed if there were no inflation
  #   nominal_required_return — CAGR you actually need to clear, including
  #                             grow-the-target-by-inflation
  #
  # The verdict uses the **nominal** number because that's the rate
  # actually demanded of the portfolio to hit the real goal.
  #
  # Output:
  #   { years_remaining:, current_value:,
  #     target_real:, target_nominal:, gap_real:, gap_nominal:,
  #     real_required_return:, nominal_required_return:,
  #     inflation_rate:, required_annual_return: <alias for nominal>,
  #     target_value: <alias for real>, gap: <alias for gap_real>,
  #     status:, verdict:, verdict_summary:, benchmarks:, citations: }
  def project(profile:, current_value:)
    return nil unless profile.is_a?(Hash)
    return nil if profile[:current_age].nil? || profile[:retirement_age].nil?
    return nil if profile[:retirement_target_value].nil?
    return nil if current_value.nil? || current_value.to_f <= 0

    years = (profile[:retirement_age].to_i - profile[:current_age].to_i)
    return nil if years <= 0

    cv             = current_value.to_f.round(2)
    target_real    = profile[:retirement_target_value].to_f.round(2)
    inflation_rate = (profile[:inflation_assumption_rate] || 0.0).to_f
    inflation_factor = (1.0 + inflation_rate) ** years
    target_nominal = (target_real * inflation_factor).round(2)

    real_required    = required_annual_return(current_value: cv, target_value: target_real, years: years)
    nominal_required = required_annual_return(current_value: cv, target_value: target_nominal, years: years)

    gap_real    = (target_real    - cv).round(2)
    gap_nominal = (target_nominal - cv).round(2)

    status =
      if cv >= target_nominal  then 'at_goal'
      elsif nominal_required.nil? then nil
      else 'short'
      end

    verdict, verdict_summary = verdict_for(required: nominal_required, status: status)
    spending_bundle = spending_analysis(profile: profile, target_real: target_real)

    {
      years_remaining:         years,
      current_value:           cv,

      # Inflation-aware fields (the new authoritative ones)
      target_real:             target_real,
      target_nominal:          target_nominal,
      gap_real:                gap_real,
      gap_nominal:             gap_nominal,
      real_required_return:    real_required,
      nominal_required_return: nominal_required,
      inflation_rate:          inflation_rate,

      # Aliases preserved for any caller that already used the simpler shape
      target_value:            target_real,
      gap:                     gap_real,
      required_annual_return:  nominal_required,

      status:                  status,
      verdict:                 verdict,
      verdict_summary:         verdict_summary,
      spending:                spending_bundle,
      benchmarks:              HISTORICAL_BENCHMARKS,
      citations:               CITATIONS
    }
  end

  # Retirement-phase analysis. Returns nil when the user hasn't set
  # `monthly_retirement_spending` — the view should hide the section
  # entirely in that case.
  #
  # All math is in REAL (today's-dollars) terms — withdrawal grows with
  # inflation each year, balance earns the real return, so working in real
  # terms eliminates inflation from the recurrence and keeps the answer
  # interpretable ("how many years of today's-equivalent spending will
  # this fund?").
  #
  # Output:
  #   { monthly_target_real:, annual_target_real:,
  #     starting_balance_real:,            # = target_real (the goal)
  #     post_retirement_real_return:,      # echoed from profile
  #     withdrawal_rate:,                  # annual_target / starting_balance
  #     sustainable_monthly_real:,         # the perpetual rate at this real return
  #     sustainable_annual_real:,
  #     years_portfolio_lasts:,            # Float::INFINITY when sustainable
  #     verdict: <symbol>, verdict_summary: <string> }
  def spending_analysis(profile:, target_real:)
    return nil unless profile.is_a?(Hash)
    monthly = profile[:monthly_retirement_spending]
    return nil if monthly.nil? || monthly.to_f <= 0
    return nil if target_real.nil? || target_real.to_f <= 0

    real_return = (profile[:post_retirement_real_return] || 0.04).to_f
    monthly_real = monthly.to_f
    annual_real  = (monthly_real * 12).round(2)

    sustainable_annual_real  = (real_return * target_real).round(2)
    sustainable_monthly_real = (sustainable_annual_real / 12.0).round(2)

    years = years_until_depletion(
      starting_balance: target_real,
      annual_withdrawal: annual_real,
      real_return: real_return
    )
    withdrawal_rate = (annual_real / target_real).round(6)

    verdict, verdict_summary = spending_verdict(
      years_lasts: years,
      monthly_real: monthly_real,
      sustainable_monthly: sustainable_monthly_real,
      withdrawal_rate: withdrawal_rate,
      real_return: real_return
    )

    {
      monthly_target_real:         monthly_real.round(2),
      annual_target_real:          annual_real,
      starting_balance_real:       target_real.to_f.round(2),
      post_retirement_real_return: real_return,
      withdrawal_rate:             withdrawal_rate,
      sustainable_monthly_real:    sustainable_monthly_real,
      sustainable_annual_real:     sustainable_annual_real,
      years_portfolio_lasts:       years,
      verdict:                     verdict,
      verdict_summary:             verdict_summary
    }
  end

  # Years until depletion under a constant-real-withdrawal annuity.
  #
  # Math:
  #   n = -ln(1 - r·B/W) / ln(1+r)   when r ≠ 0 and r·B/W < 1
  #   n = B / W                      when r = 0
  #   ∞                              when r·B ≥ W (earnings cover withdrawal forever)
  #
  # Returns Float::INFINITY when sustainable, a finite Float otherwise.
  def years_until_depletion(starting_balance:, annual_withdrawal:, real_return:)
    return Float::INFINITY if annual_withdrawal <= 0
    return starting_balance.to_f / annual_withdrawal.to_f if real_return.zero?
    ratio = (real_return * starting_balance.to_f) / annual_withdrawal.to_f
    return Float::INFINITY if ratio >= 1.0
    -Math.log(1 - ratio) / Math.log(1 + real_return)
  end

  # Map the spending analysis to a verdict bucket. Thresholds anchored to the
  # Trinity study / 4% rule: a typical retirement plans for ~30 years.
  def spending_verdict(years_lasts:, monthly_real:, sustainable_monthly:, withdrawal_rate:, real_return:)
    pct       = (withdrawal_rate * 100).round(2)
    swr_pct   = (real_return * 100).round(1)
    diff_mo   = (monthly_real - sustainable_monthly).round(2)

    if years_lasts.infinite?
      [:perpetual,
       "Sustainable indefinitely. At a #{swr_pct}% post-retirement real return, the portfolio's earnings cover " \
       "the withdrawal — principal stays intact. Implied withdrawal rate is #{pct}%, at or below the sustainable " \
       "rate of #{swr_pct}%."]
    elsif years_lasts >= 40
      [:comfortable,
       "Comfortably funded. Portfolio lasts ~#{years_lasts.round} years at this spending rate — well past a " \
       "typical 30-year retirement, with margin for sequence-of-returns shocks."]
    elsif years_lasts >= 30
      [:thirty_year_safe,
       "Covers a typical 30-year retirement. Portfolio lasts ~#{years_lasts.round} years at this spending rate, " \
       "matching the standard 4% rule horizon. Implied withdrawal rate is #{pct}%."]
    elsif years_lasts >= 25
      [:tight,
       "Tight margin. Portfolio lasts ~#{years_lasts.round} years — close to a typical retirement length but " \
       "with little room for early bear markets. Spending is roughly $#{format('%.0f', diff_mo)}/month above the " \
       "indefinitely-sustainable rate."]
    elsif years_lasts >= 15
      [:underfunded,
       "Underfunded. Portfolio lasts only ~#{years_lasts.round} years at #{pct}% withdrawal — meaningful risk " \
       "of running out before the end of retirement. Reduce spending toward $#{format('%.0f', sustainable_monthly)}/month, " \
       "raise the target, or extend the time horizon."]
    else
      [:severely_underfunded,
       "Severely underfunded. Portfolio lasts only ~#{years_lasts.round} years at this spending rate. The " \
       "indefinitely-sustainable monthly is $#{format('%.0f', sustainable_monthly)} at a #{swr_pct}% real return."]
    end
  end

  # Map the required CAGR to a four-bucket verdict. Thresholds anchored to
  # the historical benchmarks above — 5% sits below the 10-yr Treasury
  # average, 8% matches a 60/40 nominal CAGR, 10% is roughly the S&P 500's
  # long-run nominal CAGR. Anything beyond the S&P average is unlikely to
  # hold over a multi-year window without concentrated bets.
  #
  # Returns [verdict_symbol, human_summary_string].
  def verdict_for(required:, status:)
    return [:at_goal, 'You are already at or above your target. Required CAGR is 0%.'] if status == 'at_goal'
    return [:unknown, 'Not enough information to render a verdict.'] if required.nil?

    pct = (required * 100).round(2)
    case required
    when 0..0.05
      [:on_track_safe,
       "On track. A required CAGR of #{pct}% sits below the long-run 10-yr Treasury return — historically " \
       "achievable from a bond-heavy or balanced portfolio."]
    when 0.05..0.08
      [:on_track_balanced,
       "On track. A required CAGR of #{pct}% is in line with the long-run 60/40 stock/bond nominal CAGR " \
       "(~8%), so a balanced portfolio has historically met this hurdle."]
    when 0.08..0.10
      [:tight_equity,
       "Tight. A required CAGR of #{pct}% is between the 60/40 portfolio's ~8% historical CAGR and the " \
       "S&P 500's ~10% — achievable only with an equity-heavy allocation, and with no margin for sequence " \
       "risk near retirement."]
    else
      [:not_on_track,
       "Not on track at historical norms. A required CAGR of #{pct}% exceeds the S&P 500's ~10% long-run " \
       "nominal CAGR. Sustaining returns above the broad-equity average over a multi-year window is " \
       "historically rare; consider raising contributions or extending the time horizon."]
    end
  end
end
