require 'date'
require_relative 'import_snapshot_store'

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
  # value is an array of {date:, market_value:, last_price:} sorted
  # oldest-first. Use this for sparklines.
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
          last_price:   (p['last_price'] || p[:last_price]).to_f
        }
      end
    end
    out.each_value { |arr| arr.sort_by! { |r| r[:date].to_s } }
    out
  end

  # Sparkline data for one symbol, oldest-first. Empty array when the
  # symbol never appeared. Tiny slice of `per_symbol_series` for callers
  # that only want one symbol.
  def series_for(symbol, source: 'fidelity')
    sym = symbol.to_s.upcase
    snapshots = load_snapshots(source: source)
    snapshots.flat_map { |snap|
      pos = Array(snap['positions']).find { |p| (p['symbol'] || p[:symbol]).to_s.upcase == sym }
      next [] unless pos
      [{ date: snap['file_date'], market_value: value_of(pos).round(2),
         last_price: (pos['last_price'] || pos[:last_price]).to_f }]
    }.sort_by { |r| r[:date].to_s }
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
