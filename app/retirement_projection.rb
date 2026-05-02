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
  # Output:
  #   { years_remaining:, current_value:, target_value:, gap:,
  #     required_annual_return:, status: 'at_goal' | 'short' | nil }
  def project(profile:, current_value:)
    return nil unless profile.is_a?(Hash)
    return nil if profile[:current_age].nil? || profile[:retirement_age].nil?
    return nil if profile[:retirement_target_value].nil?
    return nil if current_value.nil? || current_value.to_f <= 0

    years = (profile[:retirement_age].to_i - profile[:current_age].to_i)
    return nil if years <= 0

    cv  = current_value.to_f.round(2)
    tv  = profile[:retirement_target_value].to_f.round(2)
    gap = (tv - cv).round(2)

    required = required_annual_return(current_value: cv, target_value: tv, years: years)
    status   =
      if cv >= tv      then 'at_goal'
      elsif required.nil? then nil
      else 'short'
      end

    verdict, verdict_summary = verdict_for(required: required, status: status)

    {
      years_remaining:        years,
      current_value:          cv,
      target_value:           tv,
      gap:                    gap,
      required_annual_return: required,
      status:                 status,
      verdict:                verdict,
      verdict_summary:        verdict_summary,
      benchmarks:             HISTORICAL_BENCHMARKS,
      citations:              CITATIONS
    }
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
