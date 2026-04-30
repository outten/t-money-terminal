require_relative 'market_data_service'
require_relative 'symbol_index'
require_relative 'portfolio_store'
require_relative 'watchlist_store'

# RefreshUniverse — the canonical "list of symbols this app cares about"
# used by every refresh / prefetch / scheduler script. Single source of truth
# so a new caller (e.g. an HTTP-triggered refresh route) can't drift away.
#
# Default components (deduped, uppercased):
#   1. MarketDataService::REGIONS — static dashboard tickers (SPY / QQQ /
#      AAPL / MSFT / ...) that drive region pages + macro panels. Always in.
#   2. PortfolioStore.symbols — user's open positions. Highest priority —
#      these are what /portfolio shows every render.
#   3. WatchlistStore.read — user's watchlist (lighter touch).
#
# Opt-in components (kept off by default to avoid burning provider budget
# on stale references):
#   • include_extensions: true — every SymbolIndex extension (every ticker
#     ever discovered or imported, accumulates over time; can grow to
#     hundreds of entries the user no longer holds).
#   • include_curated:    true — the curated CURATED list (TSLA, NFLX,
#     PYPL, ...) for callers that drive the dashboard recommendation grid.
module RefreshUniverse
  module_function

  # Returns the deduped, uppercased symbol list. Order is stable: REGIONS
  # first, then portfolio, then watchlist, then optional extensions, then
  # optional curated. Useful for callers that care about iteration order
  # (rate-limit-pacing scripts refresh holdings first).
  def symbols(include_extensions: false, include_curated: false)
    pieces = []
    pieces.concat(MarketDataService::REGIONS.values.flatten)
    pieces.concat(safe_call { PortfolioStore.symbols })
    pieces.concat(safe_call { WatchlistStore.read })
    pieces.concat(safe_call { SymbolIndex.extensions.map { |row| row[0] } }) if include_extensions
    pieces.concat(SymbolIndex::CURATED.map { |row| row[0] })                  if include_curated

    # Drop CUSIPs and other non-ticker artefacts that can sneak into the
    # portfolio store via broker imports (e.g. Fidelity sometimes emits
    # 9-char CUSIP numbers in the Symbol column for bonds and brokered
    # CDs). They aren't quotable by any provider, so refreshing them just
    # burns rate-limit budget. SymbolIndex::TICKER_PATTERN requires a
    # leading [A-Z], which excludes 9-digit CUSIPs starting with a digit.
    pieces
      .map { |s| s.to_s.upcase }
      .reject(&:empty?)
      .select { |s| SymbolIndex.looks_like_ticker?(s) }
      .uniq
  end

  # Same set categorised so callers can apply provider-aware policies
  # (e.g. don't fetch FMP fundamentals for ETFs).
  def categorise(include_extensions: false, include_curated: false)
    list   = symbols(include_extensions: include_extensions, include_curated: include_curated)
    etfs   = list.select { |s| MarketDataService::SYMBOL_TYPES[s] == 'ETF' }
    equity = list - etfs
    { all: list, etfs: etfs, equity: equity }
  end

  # Was the symbol added by the user (portfolio / watchlist / extension)
  # rather than baked into REGIONS? Lets refresh scripts log "user-added"
  # for transparency.
  def user_added?(symbol)
    sym = symbol.to_s.upcase
    return false if MarketDataService::REGIONS.values.flatten.include?(sym)
    true
  end

  def safe_call
    yield || []
  rescue StandardError => e
    warn "[RefreshUniverse] fell back to [] after #{e.class}: #{e.message}"
    []
  end
end
