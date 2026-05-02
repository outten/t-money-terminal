require 'date'
require_relative 'import_snapshot_store'
require_relative 'asset_class_mapper'

# PortfolioHistory — pivots ImportSnapshotStore snapshots into time series
# for the value-over-time chart + per-position sparklines on /portfolio.
#
# Snapshots are sparse — there's a data point per import, not per market
# day. The X axis on the chart is "import dates," not calendar days.
#
# Output (`time_series`):
#   [{ date: 'YYYY-MM-DD', total_value:, total_cost:, unrealized_pl:,
#      unrealized_pl_pct:, positions_count:,
#      day_change: <delta vs prior snapshot, $>,
#      day_change_pct: <delta vs prior snapshot, %> },
#    ...]
#   sorted oldest-first.
#
# Output (`per_symbol_series`):
#   { 'AAPL' => [{ date:, market_value:, last_price: }, ...], ... }
#   each list sorted oldest-first; symbols not in every snapshot just have
#   gaps (missing snapshots aren't interpolated).
module PortfolioHistory
  module_function

  # Total portfolio value time series, oldest-first. Skips snapshots
  # that fail to load. Each row also carries the day-over-day delta
  # vs the prior point so the chart tooltip can surface direction
  # without re-deriving.
  def time_series(source: 'fidelity')
    snapshots = load_snapshots(source: source)
    return [] if snapshots.empty?

    rows = snapshots.map do |snap|
      positions = Array(snap['positions'])
      total_value = positions.sum { |p| value_of(p) }.round(2)
      total_cost  = positions.sum { |p| cost_of(p) }.round(2)
      pl          = (total_value - total_cost).round(2)
      pl_pct      = total_cost.positive? ? (pl / total_cost) : nil

      {
        date:              snap['file_date'],
        total_value:       total_value,
        total_cost:        total_cost,
        unrealized_pl:     pl,
        unrealized_pl_pct: pl_pct ? pl_pct.round(6) : nil,
        positions_count:   positions.length
      }
    end

    rows.each_with_index.map do |row, i|
      prior = i.zero? ? nil : rows[i - 1]
      row.merge(
        day_change:     prior ? (row[:total_value] - prior[:total_value]).round(2) : nil,
        day_change_pct: prior && prior[:total_value].positive? ?
                          ((row[:total_value] - prior[:total_value]) / prior[:total_value]).round(6) : nil
      )
    end
  end

  # Per-symbol time series. Returns a hash keyed by upcased symbol; each
  # value is an array of {date:, market_value:, cost_value:, last_price:}
  # sorted oldest-first. Use this for sparklines and the underwater-streak
  # check on tax-harvest candidates.
  def per_symbol_series(source: 'fidelity')
    snapshots = load_snapshots(source: source)
    out = Hash.new { |h, k| h[k] = [] }
    snapshots.each do |snap|
      Array(snap['positions']).each do |p|
        sym = (p['symbol'] || p[:symbol]).to_s.upcase
        next if sym.empty?
        out[sym] << {
          date:         snap['file_date'],
          market_value: value_of(p).round(2),
          cost_value:   cost_of(p).round(2),
          last_price:   (p['last_price'] || p[:last_price]).to_f
        }
      end
    end
    out.each_value { |arr| arr.sort_by! { |r| r[:date].to_s } }
    out
  end

  # Sparkline data for one symbol, oldest-first. Empty array when the
  # symbol never appeared.
  def series_for(symbol, source: 'fidelity')
    sym = symbol.to_s.upcase
    snapshots = load_snapshots(source: source)
    snapshots.flat_map { |snap|
      pos = Array(snap['positions']).find { |p| (p['symbol'] || p[:symbol]).to_s.upcase == sym }
      next [] unless pos
      [{ date:         snap['file_date'],
         market_value: value_of(pos).round(2),
         cost_value:   cost_of(pos).round(2),
         last_price:   (pos['last_price'] || pos[:last_price]).to_f }]
    }.sort_by { |r| r[:date].to_s }
  end

  # Number of consecutive snapshots ending at the latest one where this
  # symbol's market_value was < cost_value. Returns nil if the symbol has
  # no history or isn't currently underwater. Otherwise:
  #   { snapshots: N, since: 'YYYY-MM-DD', days: Integer, currently_underwater: true }
  #
  # "Days" is calendar days from the start of the streak to today (NOT
  # the days between snapshots — we want a number the user can intuit).
  # Streak counts only consecutive underwater snapshots; one snapshot in
  # the green breaks the streak.
  def underwater_streak(symbol_or_series, source: 'fidelity')
    series =
      if symbol_or_series.is_a?(Array)
        symbol_or_series
      else
        per_symbol_series(source: source)[symbol_or_series.to_s.upcase] || []
      end
    return nil if series.empty?

    latest = series.last
    return nil unless latest[:market_value].to_f < latest[:cost_value].to_f

    streak = 0
    streak_start_date = latest[:date]
    series.reverse_each do |row|
      break unless row[:market_value].to_f < row[:cost_value].to_f
      streak += 1
      streak_start_date = row[:date]
    end

    today = Date.today
    streak_start = parse_date(streak_start_date) || today
    days = (today - streak_start).to_i
    days = 0 if days < 0

    {
      snapshots:            streak,
      since:                streak_start_date,
      days:                 days,
      currently_underwater: true
    }
  end

  def parse_date(raw)
    return raw if raw.is_a?(Date)
    Date.parse(raw.to_s)
  rescue StandardError
    nil
  end

  # Top gainers + losers across the full snapshot window, ranked by **price**
  # change (NOT market-value change). Using market-value would conflate price
  # action with share additions/sales — a position that grew from $15 → $475
  # because the user bought more shares would show up as a +3000% "gainer."
  # We want to surface the security's price movement only, so we rank by
  # per-share `last_price` ratio.
  #
  # Skips positions whose first OR last market_value is below `min_value` —
  # tiny line items create noise in the % rankings.
  #
  # Returns:
  #   { top_gainers: [{symbol:, change_pct:, change_value:, first_price:,
  #                    last_price:, first_date:, last_date:, series: [...]}, ...],
  #     top_losers:  [{...}, ...],
  #     window:      { from: 'YYYY-MM-DD', to: 'YYYY-MM-DD', snapshots: N } }
  #
  # `change_value` = shares the user currently holds × (last_price - first_price).
  # That's "what the price move did to my current position."
  #
  # `series` is the full per-symbol time series (used by the view for the
  # sparkline alongside each row).
  def movers(top_n: 5, source: 'fidelity', min_value: 1000)
    snapshots = load_snapshots(source: source)
    return { top_gainers: [], top_losers: [], window: nil } if snapshots.length < 2

    per_sym = per_symbol_series(source: source)
    rows = []

    per_sym.each do |sym, series|
      next if series.length < 2
      first = series.first
      last  = series.last
      first_price = first[:last_price].to_f
      last_price  = last[:last_price].to_f
      next if first_price <= 0 || last_price <= 0
      next if first[:market_value].to_f < min_value && last[:market_value].to_f < min_value

      # Skip when shares changed substantially between first and last
      # snapshot — could be a stock split (price changes, shares change
      # inversely), a buy/sell, or a broker data inconsistency. In any of
      # these cases the raw price ratio is misleading. We use 5%
      # tolerance to absorb dividend reinvestment without false positives.
      first_shares = first_price.positive? ? (first[:market_value].to_f / first_price) : 0
      last_shares  = last_price.positive?  ? (last[:market_value].to_f  / last_price)  : 0
      next if first_shares <= 0 || last_shares <= 0
      shares_drift = ((last_shares - first_shares) / first_shares).abs
      next if shares_drift > 0.05

      change_pct = ((last_price - first_price) / first_price).round(6)
      shares_now = last_shares
      change_value = (shares_now * (last_price - first_price)).round(2)

      rows << {
        symbol:       sym,
        change_pct:   change_pct,
        change_value: change_value,
        first_price:  first_price.round(4),
        last_price:   last_price.round(4),
        first_date:   first[:date],
        last_date:    last[:date],
        series:       series
      }
    end

    sorted = rows.sort_by { |r| -r[:change_pct] }
    {
      top_gainers: sorted.first(top_n),
      top_losers:  sorted.reverse.first(top_n).reject { |r| r[:change_pct] >= 0 },
      window: {
        from:      snapshots.first['file_date'],
        to:        snapshots.last['file_date'],
        snapshots: snapshots.length
      }
    }
  end

  # Asset-class breakdown of the latest snapshot. Thin wrapper around
  # AssetClassMapper.breakdown — pulls the latest snapshot's positions and
  # delegates the classification + summing.
  def allocation_breakdown(source: 'fidelity')
    snapshots = load_snapshots(source: source)
    return { rows: [], total_value: 0.0, as_of: nil } if snapshots.empty?
    latest = snapshots.last
    rows   = AssetClassMapper.breakdown(latest['positions'] || [])
    {
      rows:        rows,
      total_value: rows.sum { |r| r[:value] }.round(2),
      as_of:       latest['file_date']
    }
  end

  # Render a tiny inline SVG polyline for the per-position sparkline column.
  # Returns an HTML-safe string (no <script>, no escapes needed in ERB raw).
  # Color: green if last >= first, red otherwise. Empty / single-point
  # series renders an em-dash.
  def sparkline_svg(series, width: 80, height: 24, padding: 2)
    values = series.map { |r| r[:market_value].to_f }.reject { |v| v.nan? || v.infinite? }
    return '<span class="muted">—</span>' if values.length < 2

    min, max = values.minmax
    range = max - min
    range = 1.0 if range.zero? # flat line

    inner_w = width - 2 * padding
    inner_h = height - 2 * padding
    n = values.length - 1

    points = values.each_with_index.map { |v, i|
      x = padding + (i.to_f / n) * inner_w
      y = padding + inner_h - ((v - min) / range) * inner_h
      "#{x.round(2)},#{y.round(2)}"
    }.join(' ')

    color = values.last >= values.first ? '#0a8a3a' : '#b00020'
    %(<svg width="#{width}" height="#{height}" viewBox="0 0 #{width} #{height}" ) +
      %(xmlns="http://www.w3.org/2000/svg" aria-label="value trajectory" role="img">) +
      %(<polyline fill="none" stroke="#{color}" stroke-width="1.5" stroke-linecap="round" ) +
      %(stroke-linejoin="round" points="#{points}" /></svg>)
  end

  # --- internals -----------------------------------------------------------

  def load_snapshots(source:)
    ImportSnapshotStore.list(source: source)
                       .reverse # list returns newest-first; we want oldest-first
                       .map    { |meta| ImportSnapshotStore.send(:read_path, meta[:path]) }
                       .compact
                       .reject { |snap| snap['file_date'].to_s.strip.empty? }
                       .sort_by { |snap| snap['file_date'].to_s }
  end

  # Snapshot positions sometimes carry `current_value` (the broker-provided
  # market value) and sometimes only `shares` × `last_price`. Use the
  # broker number when present so we agree with what the user sees in
  # Fidelity, falling back to the computed value otherwise.
  def value_of(pos)
    explicit = pos['current_value'] || pos[:current_value] || pos['market_value'] || pos[:market_value]
    return explicit.to_f if explicit
    shares = (pos['shares']     || pos[:shares]).to_f
    price  = (pos['last_price'] || pos[:last_price]).to_f
    shares * price
  end

  def cost_of(pos)
    explicit = pos['cost_value'] || pos[:cost_value]
    return explicit.to_f if explicit
    shares = (pos['shares']     || pos[:shares]).to_f
    basis  = (pos['cost_basis'] || pos[:cost_basis]).to_f
    shares * basis
  end
end
