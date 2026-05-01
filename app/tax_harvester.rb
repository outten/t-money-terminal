require 'date'
require_relative 'tax_lot'
require_relative 'wash_sale'

# TaxHarvester — identify loss-harvesting candidates, estimate tax savings,
# detect short-to-long threshold crossings, and recommend an action per
# candidate based on the user's risk tolerance + retirement timeline.
#
# Inputs:
#   - positions:  PortfolioStore.positions valuated by valuate_position
#                 (each row has :lots, :current_price, :symbol, etc.)
#   - profile:    ProfileStore.read hash (current_age, retirement_age,
#                 risk_tolerance, federal_ltcg_rate, federal_ordinary_rate,
#                 state_tax_rate, niit_applies)
#   - trades:     TradesStore.read (used by WashSale + YTD summary)
#
# Output (`analyse`):
#   {
#     profile:           {...},               # echo of inputs for the view
#     candidates:        [...],               # loss-harvest candidates
#     crossing_threshold: [...],              # lots about to flip ST → LT
#     ytd:               { realized_short:, realized_long:, net:,
#                          ordinary_offset_used:, ordinary_offset_cap:,
#                          ordinary_offset_remaining: },
#     totals:            { lots_examined:, lots_with_loss:, total_unrealized_loss:,
#                          total_estimated_savings: }
#   }
#
# IMPORTANT: this is decision-support, not tax advice. The view always
# renders a disclaimer.
module TaxHarvester
  ORDINARY_OFFSET_CAP = 3_000        # IRS net cap-loss against ordinary income (annual, US)
  CROSSING_WINDOW_DAYS = 30          # "becomes long-term in ≤ N days"

  # Risk-tolerance thresholds: minimum unrealized-loss size (% of cost basis)
  # at which we recommend harvesting. Smaller losses get a "skip — too small"
  # recommendation for conservative profiles.
  HARVEST_THRESHOLDS = {
    'aggressive'   => 0.005,  # 0.5%
    'moderate'     => 0.020,  # 2%
    'conservative' => 0.050   # 5%
  }.freeze

  # Heuristic substantially-not-identical replacements. Idea: realise the
  # loss, immediately rotate into a different-but-correlated security so
  # your market exposure doesn't change for the 31-day wash-sale window.
  # Pairs match different INDICES, not just different tickers tracking the
  # same one (SPY ↔ VOO ↔ IVV all track the S&P 500 — likely substantially
  # identical). When in doubt, the safe move is no replacement (sit out
  # the 31 days).
  REPLACEMENT_SUGGESTIONS = {
    # S&P 500 ETFs → swap to Total Market or Large-cap Growth
    'SPY'  => %w[VTI ITOT SCHB],
    'VOO'  => %w[VTI ITOT SCHB],
    'IVV'  => %w[VTI ITOT SCHB],
    # Nasdaq-100 → swap to broad large-cap growth
    'QQQ'  => %w[VUG SCHG MGK],
    # Total market → swap to S&P 500 (close but tracks a different index)
    'VTI'  => %w[VOO IVV],
    'ITOT' => %w[VOO IVV],
    'SCHB' => %w[VOO IVV],
    # Dividend-focused
    'SCHD' => %w[VYM HDV DGRO],
    'VYM'  => %w[SCHD HDV],
    'HDV'  => %w[SCHD VYM],
    # Long-treasury
    'TLT'  => %w[VGLT EDV],
    # Gold
    'GLD'  => %w[IAU SGOL],
    'GLDM' => %w[IAU SGOL],
    # Tech sector
    'XLK'  => %w[VGT FTEC],
    # Financials sector
    'XLF'  => %w[VFH IYF]
  }.freeze

  module_function

  # The main entry-point. Returns the full analysis bundle.
  def analyse(positions:, profile:, trades:)
    cands = candidates(positions: positions, profile: profile, trades: trades)
    cross = crossing_threshold(positions: positions)
    ytd_  = ytd_summary(trades: trades)

    {
      profile:            profile,
      candidates:         cands,
      crossing_threshold: cross,
      ytd:                ytd_,
      totals:             {
        lots_examined:           positions.sum { |p| (p[:lots] || []).length },
        lots_with_loss:          cands.length,
        total_unrealized_loss:   cands.sum { |c| c[:unrealized_pl] }.round(2),
        total_estimated_savings: cands.sum { |c| c[:estimated_tax_savings].to_f }.round(2)
      },
      generated_at:       Time.now.utc.iso8601
    }
  end

  # All open lots currently underwater, ranked by estimated tax savings.
  # Each candidate row carries everything the view needs to render a row
  # without recomputing.
  def candidates(positions:, profile:, trades:)
    today_iso = Date.today.iso8601
    threshold_pct = HARVEST_THRESHOLDS[profile[:risk_tolerance]] || HARVEST_THRESHOLDS['moderate']
    rows = []

    positions.each do |pos|
      next unless pos[:current_price] && pos[:current_price].to_f.positive?
      Array(pos[:lots]).each do |lot|
        shares = lot[:shares].to_f
        basis  = lot[:cost_basis].to_f
        next if shares <= 0 || basis <= 0

        cost  = shares * basis
        value = shares * pos[:current_price].to_f
        pl    = (value - cost).round(2)
        next if pl >= 0

        loss_pct = (-pl) / cost
        tax = TaxLot.classify(lot: lot, sold_at: today_iso)

        # If a same-symbol BUY landed within ±30 days, harvesting now
        # would trigger the wash-sale rule. Surface that as a flag on the
        # candidate (without blocking — user might still want to act).
        # WashSale.check takes a single positional breakdown hash.
        wash = WashSale.check({
          symbol:        pos[:symbol],
          shares_closed: shares,
          price:         pos[:current_price].to_f,
          sold_at:       today_iso,
          realized_pl:   pl
        })

        rows << {
          symbol:                  pos[:symbol],
          lot_id:                  lot[:id],
          shares:                  shares,
          cost_basis:              basis,
          current_price:           pos[:current_price].to_f,
          cost_value:              cost.round(2),
          market_value:            value.round(2),
          unrealized_pl:           pl,
          loss_pct:                loss_pct.round(4),
          holding_period:          tax[:holding_period],
          days_held:               tax[:days_held],
          acquired_at_effective:   tax[:acquired_at_effective],
          acquired_at_source:      tax[:source],
          estimated_tax_savings:   estimated_savings(loss: -pl, holding_period: tax[:holding_period], profile: profile),
          marginal_rate_applied:   marginal_rate(holding_period: tax[:holding_period], profile: profile),
          wash_sale_flags:         wash,
          replacement_suggestions: REPLACEMENT_SUGGESTIONS[pos[:symbol]] || [],
          recommendation:          recommend(loss_pct: loss_pct, holding_period: tax[:holding_period],
                                             days_held: tax[:days_held], wash_flags: wash,
                                             profile: profile, threshold_pct: threshold_pct)
        }
      end
    end

    rows.sort_by { |r| -r[:estimated_tax_savings].to_f }
  end

  # Lots that will flip from short-term to long-term within
  # CROSSING_WINDOW_DAYS days. Useful warning: don't realise a short-term
  # loss now if it would have flipped to long-term anyway (and a long-term
  # loss is taxed at the lower long-term rate, so realising long-term is
  # less powerful from a $-saved perspective — but it preserves the
  # carryforward without time pressure).
  #
  # Conversely, large unrealised GAINS becoming long-term soon are flagged
  # so the user knows when to act if they're considering a sell.
  def crossing_threshold(positions:)
    today_iso = Date.today.iso8601
    threshold = TaxLot::LONG_TERM_THRESHOLD_DAYS
    out = []

    positions.each do |pos|
      Array(pos[:lots]).each do |lot|
        tax = TaxLot.classify(lot: lot, sold_at: today_iso)
        next unless tax[:holding_period] == 'short' && tax[:days_held]

        days_to_long = threshold + 1 - tax[:days_held]
        next if days_to_long > CROSSING_WINDOW_DAYS || days_to_long < 0

        cost  = lot[:shares].to_f * lot[:cost_basis].to_f
        value = pos[:current_price] ? lot[:shares].to_f * pos[:current_price].to_f : nil
        pl    = value ? (value - cost).round(2) : nil

        out << {
          symbol:                pos[:symbol],
          lot_id:                lot[:id],
          shares:                lot[:shares],
          cost_basis:            lot[:cost_basis],
          current_price:         pos[:current_price],
          unrealized_pl:         pl,
          days_held:             tax[:days_held],
          days_to_long_term:     days_to_long,
          acquired_at_effective: tax[:acquired_at_effective],
          acquired_at_source:    tax[:source]
        }
      end
    end

    out.sort_by { |r| r[:days_to_long_term] }
  end

  # YTD realised summary + how much of the $3k ordinary-offset cap is
  # already used.
  def ytd_summary(trades:)
    today      = Date.today
    year_start = Date.new(today.year, 1, 1)
    sells = trades.select do |t|
      next false unless t[:side] == 'sell'
      d = parse_date(t[:date])
      d && d >= year_start && d <= today
    end

    short = sells.sum { |t| t[:short_term_pl].to_f }.round(2)
    long  = sells.sum { |t| t[:long_term_pl].to_f }.round(2)
    net   = (short + long).round(2)

    # If net is negative, you can offset up to $3,000 against ordinary
    # income; remainder carries forward indefinitely.
    used_offset = net < 0 ? [(-net), ORDINARY_OFFSET_CAP].min : 0
    {
      realized_short:            short,
      realized_long:             long,
      net:                       net,
      ordinary_offset_cap:       ORDINARY_OFFSET_CAP,
      ordinary_offset_used:      used_offset.round(2),
      ordinary_offset_remaining: (ORDINARY_OFFSET_CAP - used_offset).round(2),
      carryforward_estimate:     net < -ORDINARY_OFFSET_CAP ? (-net - ORDINARY_OFFSET_CAP).round(2) : 0
    }
  end

  # Marginal rate applied to a hypothetical realised loss of `loss` dollars
  # in the given holding period. Combines federal + optional state +
  # optional NIIT.
  def estimated_savings(loss:, holding_period:, profile:)
    rate = marginal_rate(holding_period: holding_period, profile: profile)
    (loss.abs * rate).round(2)
  end

  def marginal_rate(holding_period:, profile:)
    fed = case holding_period
          when 'long' then profile[:federal_ltcg_rate].to_f
          else             profile[:federal_ordinary_rate].to_f
          end
    state = profile[:state_tax_rate].to_f
    niit  = profile[:niit_applies] ? 0.038 : 0.0
    (fed + state + niit).round(4)
  end

  # The action recommendation per candidate, branched by risk tolerance,
  # loss size, holding period, days-to-LT, and wash-sale risk.
  #
  # Possible recommendations: 'harvest' / 'wait' / 'skip'
  def recommend(loss_pct:, holding_period:, days_held:, wash_flags:, profile:, threshold_pct:)
    return { action: 'skip', reason: 'wash-sale risk: same-symbol BUY within ±30 days. Wait or use a replacement security.' } if wash_flags && !wash_flags.empty?
    return { action: 'skip', reason: "loss too small (< #{(threshold_pct * 100).round(1)}% of cost basis at #{profile[:risk_tolerance]} risk tolerance)." } if loss_pct < threshold_pct

    # Short-term loss with the long-term threshold within 30 days: think
    # twice. A short-term loss at the user's ordinary rate is more
    # valuable than a long-term loss at the LTCG rate, so harvesting now
    # IS preferable in pure $ terms — but a conservative profile may
    # still prefer to wait if the savings differential is small.
    if holding_period == 'short' && days_held && (TaxLot::LONG_TERM_THRESHOLD_DAYS + 1 - days_held).between?(0, 30)
      days_to_long = TaxLot::LONG_TERM_THRESHOLD_DAYS + 1 - days_held
      if profile[:risk_tolerance] == 'conservative'
        return { action: 'wait', reason: "becomes long-term in #{days_to_long} day(s); conservative profile suggests waiting." }
      end
      return { action: 'harvest', reason: "short-term loss at ordinary rate is the bigger tax shield; harvesting before long-term threshold (#{days_to_long}d away) maximises savings." }
    end

    # Default: harvest.
    reason =
      if holding_period == 'long'
        "long-term loss; offsets future long-term gains at #{profile[:federal_ltcg_rate] * 100}% rate, plus up to $#{ORDINARY_OFFSET_CAP} of ordinary income annually."
      else
        "short-term loss; offsets ordinary income at #{profile[:federal_ordinary_rate] * 100}% rate (the most valuable kind of loss)."
      end
    { action: 'harvest', reason: reason }
  end

  def parse_date(raw)
    return raw if raw.is_a?(Date)
    Date.parse(raw.to_s)
  rescue StandardError
    nil
  end
end
