require 'csv'
require 'date'
require_relative 'symbol_index'
require_relative 'portfolio_store'
require_relative 'market_data_service'
require_relative 'import_snapshot_store'

# FidelityImporter — parse a Fidelity Portfolio_Positions CSV and reconcile
# it into PortfolioStore.
#
# Drop a daily export at `data/porfolio/fidelity/Portfolio_Positions_<Mmm>-<DD>-<YYYY>.csv`
# (the directory name's spelled with the typo Fidelity ships) and call
# `FidelityImporter.import!` — by default it imports the newest file in that
# directory.
#
# Behaviour
# ---------
# - File is authoritative for the symbols it contains. For each symbol we
#   wipe existing PortfolioStore lots and replace with a single lot at the
#   file's average cost basis. Symbols NOT in the file are left alone, so
#   manual entries persist.
# - Unknown tickers are added as SymbolIndex extensions (source: 'fidelity')
#   so /analysis/:symbol works for them and the search box can find them.
# - Last Price from the file is primed into the MarketDataService quote
#   cache so /portfolio renders fast even when live providers are degraded.
# - Cash/money-market rows (SPAXX**, USD***), pending-activity rows, and
#   non-CSV footer lines are skipped with a recorded reason.
# - Multi-account holdings (e.g. NVDA in both Individual and ROTH IRA) are
#   aggregated to a single position with weighted-average cost basis. The
#   accounts each symbol appears in are recorded in :accounts.
module FidelityImporter
  DEFAULT_DIR  = File.expand_path('../../data/porfolio/fidelity', __FILE__)
  FILE_PATTERN = /\APortfolio_Positions_(\w{3})-(\d{2})-(\d{4})\.csv\z/.freeze
  MONTH_INDEX  = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec]
                   .each_with_index.to_h { |m, i| [m, i + 1] }.freeze

  module_function

  def default_dir
    ENV['FIDELITY_IMPORT_DIR'] || DEFAULT_DIR
  end

  # Newest CSV in `dir` by filename date, falling back to mtime.
  def latest_file_in(dir = nil)
    dir ||= default_dir
    return nil unless Dir.exist?(dir)
    files = Dir.glob(File.join(dir, '*.csv'))
    return nil if files.empty?
    files.max_by { |path| [extract_date_from_filename(path) || Date.new(0), File.mtime(path)] }
  end

  def extract_date_from_filename(path)
    base = File.basename(path)
    m = base.match(FILE_PATTERN)
    return nil unless m
    month = MONTH_INDEX[m[1]]
    return nil unless month
    Date.new(m[3].to_i, month, m[2].to_i)
  rescue ArgumentError
    nil
  end

  # Parse a Fidelity CSV. Returns:
  #   { file_path:, file_date:, positions: [...], skipped: [...] }
  # Multi-account symbols collapse to a single :positions entry.
  def parse(path)
    raw = File.read(path, encoding: 'bom|utf-8')
    rows = CSV.parse(raw, headers: true)

    aggregated = {}
    accounts   = Hash.new { |h, k| h[k] = [] }
    skipped    = []

    rows.each do |row|
      sym  = row['Symbol'].to_s.strip
      acct = row['Account Name'].to_s.strip
      desc = row['Description'].to_s.strip
      qty  = parse_money(row['Quantity'])

      if sym.empty? || row['Account Number'].to_s.strip.empty?
        skipped << { reason: 'non_position_row', detail: desc.empty? ? sym : desc }
        next
      end
      if sym.match?(/\*+\z/)
        skipped << { reason: 'cash_or_money_market', symbol: sym, accounts: [acct] }
        next
      end
      if sym.casecmp?('pending activity')
        skipped << { reason: 'pending_activity', accounts: [acct] }
        next
      end
      if qty.nil? || qty <= 0
        skipped << { reason: 'no_quantity', symbol: sym }
        next
      end

      price       = parse_money(row['Last Price'])
      avg_basis   = parse_money(row['Average Cost Basis'])
      cost_total  = parse_money(row['Cost Basis Total'])
      avg_basis ||= (cost_total && qty.positive? ? cost_total / qty : nil)
      current_val = parse_money(row['Current Value'])
      total_pl    = parse_money(row['Total Gain/Loss Dollar'])
      day_change  = parse_money(row['Last Price Change'])
      day_pct     = parse_money(row['Today\'s Gain/Loss Percent'])
      pct_account = parse_money(row['Percent Of Account'])

      if avg_basis.nil? || avg_basis <= 0
        skipped << { reason: 'no_cost_basis', symbol: sym }
        next
      end

      key = sym.upcase
      accounts[key] << acct unless acct.empty? || accounts[key].include?(acct)

      if (existing = aggregated[key])
        new_shares = (existing[:shares] + qty).round(6)
        new_cost   = (existing[:cost_value] + (avg_basis * qty)).round(2)
        existing[:shares]        = new_shares
        existing[:cost_value]    = new_cost
        existing[:cost_basis]    = new_shares.positive? ? (new_cost / new_shares).round(4) : avg_basis
        existing[:current_value] = (existing[:current_value].to_f + (current_val || 0)).round(2)
        existing[:total_pl]      = (existing[:total_pl].to_f      + (total_pl    || 0)).round(2)
        existing[:pct_account]   = (existing[:pct_account].to_f   + (pct_account || 0)).round(4)
      else
        aggregated[key] = {
          symbol:        key,
          description:   desc,
          shares:        qty.round(6),
          cost_basis:    avg_basis.round(4),
          cost_value:    (avg_basis * qty).round(2),
          last_price:    price,
          day_change:    day_change,
          day_change_pct: day_pct,
          current_value: current_val,
          total_pl:      total_pl,
          pct_account:   pct_account
        }
      end
    end

    aggregated.each_value { |p| p[:accounts] = accounts[p[:symbol]] }

    {
      file_path:  path,
      file_date:  extract_date_from_filename(path),
      positions:  aggregated.values.sort_by { |p| -(p[:current_value] || 0) },
      skipped:    skipped
    }
  end

  # Parse a Fidelity-formatted money/percent/quantity string.
  # Examples: "$270.17", "+$5,133.23", "-$0.54", "+85.48%", "9.696", "", "--"
  # Returns Float or nil.
  def parse_money(value)
    str = value.to_s.strip
    return nil if str.empty? || str == '--' || str.casecmp?('n/a')
    cleaned = str.gsub(/[\$,+%]/, '').strip
    return nil if cleaned.empty?
    Float(cleaned)
  rescue ArgumentError, TypeError
    nil
  end

  # Reconcile a parsed file into the live stores. Returns a summary hash:
  #   { file_path:, file_date:, imported:, replaced:, added:,
  #     symbols_registered:, primed_quotes:, busted_caches:,
  #     snapshot_path:, skipped:, positions: [...] }
  # `positions` is the parsed positions list (so callers can render results).
  #
  # Side effects on success (in order):
  #   1. Each new symbol is added to SymbolIndex extensions.
  #   2. PortfolioStore lots are replaced with the broker's single-lot
  #      aggregate (per symbol in the file).
  #   3. Quote cache is primed from the file's Last Price.
  #   4. Historical cache is busted for every imported symbol so the next
  #      /analysis fetch pulls fresh data (the position changed; the prior
  #      historical may be stale relative to the new context).
  #   5. The full parsed result is persisted to data/imports/fidelity/<basename>.json
  #      via ImportSnapshotStore for audit + cross-render reuse of broker fields.
  def import!(path: nil)
    path ||= latest_file_in
    raise 'No Fidelity CSV found' unless path

    parsed = parse(path)
    summary = {
      file_path:          parsed[:file_path],
      file_date:          parsed[:file_date],
      imported:           0,
      replaced:           0,
      added:              0,
      symbols_registered: [],
      primed_quotes:      [],
      busted_caches:      [],
      snapshot_path:      nil,
      skipped:            parsed[:skipped],
      positions:          parsed[:positions]
    }

    parsed[:positions].each do |p|
      sym = p[:symbol]

      # Register in SymbolIndex if not already known.
      unless SymbolIndex.known?(sym)
        SymbolIndex.add_extension(sym, name: p[:description].to_s.empty? ? sym : p[:description],
                                       region: 'Fidelity', source: 'fidelity')
        summary[:symbols_registered] << sym
      end

      # Replace existing PortfolioStore lots for this symbol with the broker's
      # average cost basis (single lot per symbol — Fidelity gives us only
      # the aggregate, not individual tax lots).
      had_lots = !PortfolioStore.lots_for(sym).empty?
      PortfolioStore.remove(sym)
      PortfolioStore.add_lot(
        symbol:      sym,
        shares:      p[:shares],
        cost_basis:  p[:cost_basis],
        acquired_at: nil,
        notes:       "Imported from Fidelity #{parsed[:file_date]&.iso8601 || File.basename(path)}"
      )
      summary[:imported] += 1
      had_lots ? summary[:replaced] += 1 : summary[:added] += 1

      # Bust the historical cache first so the next /analysis view fetches
      # fresh data. Quote / analyst / profile caches stay — the broker file
      # only changes the *position*, not the company-level metadata. We
      # don't pre-fetch historicals synchronously here (would block this
      # POST for minutes); the refresh happens lazily on first /analysis
      # view, or proactively via `make scheduler TIER=quotes`.
      MarketDataService.bust_historical_for_symbol!(sym)
      summary[:busted_caches] << sym

      # Prime the quote cache so /portfolio renders fast even when live
      # providers are throttled. Done after the bust so it sticks.
      if p[:last_price] && p[:last_price].positive?
        MarketDataService.prime_quote!(
          sym,
          price:      p[:last_price],
          change_pct: p[:day_change_pct],
          volume:     0
        )
        summary[:primed_quotes] << sym
      end
    end

    # Persist the full parsed payload as a snapshot. We re-prime the quote
    # cache after busting (above), so do this last to capture the final
    # imported state.
    snapshot_payload = parsed.merge(
      summary: summary.reject { |k, _| k == :positions || k == :skipped }
    )
    saved = ImportSnapshotStore.write(
      source:   'fidelity',
      basename: File.basename(path, '.csv'),
      data:     snapshot_payload
    )
    summary[:snapshot_path] = saved['path']

    summary
  end
end
