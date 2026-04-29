require_relative 'import_snapshot_store'

# PortfolioDiff — compare two ImportSnapshotStore snapshots and report what
# changed: positions added, sold, scaled up, scaled down, unchanged.
#
# Used by `/portfolio/drift` to answer "what's different since my last
# import?" — the most common question after a daily broker sync.
#
# Key API:
#   PortfolioDiff.compute(before: <snapshot>, after: <snapshot>)
#   PortfolioDiff.compute_latest_pair(source: 'fidelity')  # newest two snapshots
#
# Returns:
#   { before_meta:, after_meta:,
#     totals: { before_value:, after_value:, value_delta:,
#               added_count:, removed_count:, changed_count:, unchanged_count: },
#     rows:   [{symbol:, status:, before:, after:, shares_delta:,
#               value_delta:, pct_account_delta:}, ...] }
# `rows` is sorted by absolute value_delta descending (biggest movers first).
module PortfolioDiff
  STATUSES = %w[added removed changed unchanged].freeze

  module_function

  # Convenience: pulls the two most recent snapshots for `source` and diffs
  # them. Returns nil if fewer than 2 snapshots exist.
  def compute_latest_pair(source: 'fidelity')
    list = ImportSnapshotStore.list(source: source)
    return nil if list.length < 2
    after_path  = list[0][:path]
    before_path = list[1][:path]
    after  = ImportSnapshotStore.send(:read_path, after_path)
    before = ImportSnapshotStore.send(:read_path, before_path)
    compute(before: before, after: after)
  end

  def compute(before:, after:)
    raise ArgumentError, 'before snapshot required' unless before.is_a?(Hash)
    raise ArgumentError, 'after snapshot required'  unless after.is_a?(Hash)

    before_by_sym = index_positions(before)
    after_by_sym  = index_positions(after)

    all_symbols = (before_by_sym.keys | after_by_sym.keys).sort
    rows = all_symbols.map { |sym| diff_row(sym, before_by_sym[sym], after_by_sym[sym]) }

    rows.sort_by! { |r| -(r[:value_delta] || 0).abs }

    totals = aggregate_totals(rows, before_by_sym, after_by_sym)

    {
      before_meta: snapshot_meta(before),
      after_meta:  snapshot_meta(after),
      totals:      totals,
      rows:        rows
    }
  end

  # --- internals -----------------------------------------------------------

  def index_positions(snapshot)
    (snapshot['positions'] || []).each_with_object({}) do |p, acc|
      sym = p['symbol']&.upcase
      acc[sym] = p if sym
    end
  end

  def diff_row(symbol, before, after)
    status =
      if    before.nil? && after        then 'added'
      elsif after.nil?  && before       then 'removed'
      elsif before && after && (before['shares'].to_f - after['shares'].to_f).abs > 1e-6 then 'changed'
      else 'unchanged'
      end

    shares_delta       = (after&.dig('shares').to_f - before&.dig('shares').to_f).round(6)
    value_delta        = (after&.dig('current_value').to_f - before&.dig('current_value').to_f).round(2)
    pct_account_delta  = (after&.dig('pct_account').to_f - before&.dig('pct_account').to_f).round(4)
    cost_basis_delta   = (after&.dig('cost_basis').to_f - before&.dig('cost_basis').to_f).round(4)

    {
      symbol:            symbol,
      status:            status,
      before:            before,
      after:             after,
      shares_delta:      shares_delta,
      value_delta:       value_delta,
      pct_account_delta: pct_account_delta,
      cost_basis_delta:  cost_basis_delta
    }
  end

  def aggregate_totals(rows, before_by_sym, after_by_sym)
    before_value = before_by_sym.values.sum { |p| p['current_value'].to_f }
    after_value  = after_by_sym.values.sum  { |p| p['current_value'].to_f }

    {
      before_value:    before_value.round(2),
      after_value:     after_value.round(2),
      value_delta:     (after_value - before_value).round(2),
      value_delta_pct: before_value.positive? ? ((after_value - before_value) / before_value).round(4) : nil,
      added_count:     rows.count { |r| r[:status] == 'added' },
      removed_count:   rows.count { |r| r[:status] == 'removed' },
      changed_count:   rows.count { |r| r[:status] == 'changed' },
      unchanged_count: rows.count { |r| r[:status] == 'unchanged' }
    }
  end

  def snapshot_meta(snap)
    {
      basename:        snap['basename'],
      file_date:       snap['file_date'],
      written_at:      snap['written_at'],
      positions_count: (snap['positions'] || []).length
    }
  end
end
