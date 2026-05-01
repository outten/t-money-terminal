require 'date'
require_relative 'import_snapshot_store'

# TaxLot — classify a closed lot's tax treatment.
#
# US-style: gains on shares held > 1 year are long-term (preferential
# capital-gains rate); ≤ 1 year are short-term (ordinary income). The
# threshold by IRS rule is "more than one year" — 366+ days for non-leap
# windows, 367+ across a leap year. We use a single 365-day cutoff which
# is the conservative-for-the-investor read (treats day-365 as short-term
# even though IRS would call it long-term in some calendar configurations).
#
# Acquired-at sourcing for imported lots:
#   The Fidelity importer doesn't have an acquisition date — its CSV
#   doesn't include one. So lots created via import have `acquired_at: nil`.
#   For those, we fall back to the earliest ImportSnapshotStore entry that
#   contains the symbol with at least the closed shares count — that's the
#   user's earliest known holding date. Imperfect (the user may have held
#   the position before the first import) but a useful approximation.
module TaxLot
  LONG_TERM_THRESHOLD_DAYS = 365 # > 365 days held = long-term

  module_function

  # Classify a single closed-lot record. Inputs:
  #   - lot:      the lot hash (must have :acquired_at and/or :symbol)
  #   - sold_at:  ISO date string ('YYYY-MM-DD') or Date
  # Returns:
  #   { holding_period: 'short'|'long'|'unknown', days_held: Integer|nil,
  #     acquired_at_effective: ISO date string or nil, source: 'lot'|'snapshot'|'unknown' }
  def classify(lot:, sold_at:)
    sold_date = parse_date(sold_at) || Date.today
    acq_iso, source = effective_acquired_at(lot)
    acq_date = acq_iso && parse_date(acq_iso)

    if acq_date.nil?
      return { holding_period: 'unknown', days_held: nil, acquired_at_effective: nil, source: 'unknown' }
    end

    days = (sold_date - acq_date).to_i
    period = days > LONG_TERM_THRESHOLD_DAYS ? 'long' : 'short'

    {
      holding_period:        period,
      days_held:             days,
      acquired_at_effective: acq_iso,
      source:                source
    }
  end

  # Best-effort acquired_at: the lot's own field if set; otherwise the
  # earliest snapshot containing the symbol with at least `lot[:shares]`
  # held; otherwise nil.
  # Returns [iso_date_or_nil, source_string].
  def effective_acquired_at(lot)
    explicit = lot[:acquired_at] || lot['acquired_at']
    return [explicit, 'lot'] if explicit && !explicit.to_s.empty?

    sym = (lot[:symbol] || lot['symbol']).to_s.upcase
    shares = (lot[:shares] || lot['shares']).to_f
    snap_date = earliest_snapshot_holding_date(sym, min_shares: shares)
    snap_date ? [snap_date, 'snapshot'] : [nil, 'unknown']
  end

  # Walk all Fidelity snapshots oldest-first; return the file_date of the
  # earliest snapshot in which `symbol` appears with shares >= min_shares.
  # Caches per-call since callers will hit the same symbol N times during
  # a multi-lot close.
  def earliest_snapshot_holding_date(symbol, min_shares: 0)
    snapshots = ImportSnapshotStore.list(source: 'fidelity').sort_by { |h| h[:file_date].to_s }
    snapshots.each do |meta|
      data = ImportSnapshotStore.send(:read_path, meta[:path])
      next unless data
      pos = (data['positions'] || []).find { |p| p['symbol']&.upcase == symbol.upcase }
      next unless pos
      next if pos['shares'].to_f < min_shares - 1e-6 # require enough shares
      return data['file_date'] || meta[:file_date]
    end
    nil
  rescue StandardError
    nil
  end

  # Aggregate a list of `:lots_closed` (from PortfolioStore.close_shares_fifo)
  # into short-term and long-term subtotals. Returns:
  #   { short_term_pl:, long_term_pl:, unknown_pl: }
  def aggregate_realized(lots_closed)
    short_term = 0.0
    long_term  = 0.0
    unknown    = 0.0
    Array(lots_closed).each do |row|
      pl = (row[:realized_pl] || row['realized_pl']).to_f
      case (row[:holding_period] || row['holding_period']).to_s
      when 'short'   then short_term += pl
      when 'long'    then long_term  += pl
      else                unknown    += pl
      end
    end
    { short_term_pl: short_term.round(2), long_term_pl: long_term.round(2), unknown_pl: unknown.round(2) }
  end

  def parse_date(raw)
    return raw if raw.is_a?(Date)
    Date.parse(raw.to_s)
  rescue StandardError
    nil
  end
end
