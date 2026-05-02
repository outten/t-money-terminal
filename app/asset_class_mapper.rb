# AssetClassMapper — classify a holding into one of:
#
#   target_date   — multi-asset glide-path funds (Fidelity Freedom, T. Rowe
#                   Retirement, Vanguard Target, MFS Lifetime, etc.)
#   us_stocks     — broad US equity (S&P 500, total market, factor ETFs,
#                   actively-managed large-cap funds)
#   intl_stocks   — international + emerging markets equity
#   bonds         — treasuries, corporates, total bond, munis
#   real_estate   — REITs, real-estate funds
#   commodities   — gold, silver, broad commodities
#   balanced      — multi-asset funds that aren't year-targeted
#   cash          — money-market funds, settlement cash
#   unmapped      — symbol/description didn't match any rule
#
# Mapping order:
#   1. Explicit symbol map  (highest confidence, hand-curated)
#   2. Description regex    (catches target-date / sector / total-bond text)
#   3. Default to 'unmapped'
#
# v1 covers the user's actual top-by-value holdings (target-date, S&P 500
# index funds, intl/emerging, bonds, factor ETFs, Fidelity VIP variable
# funds). Long-tail symbols stay in `unmapped` and are honestly reported as
# such — the breakdown view shows the unmapped percentage so the user can
# see the gap and decide whether to extend the map.
module AssetClassMapper
  CLASSES = %w[target_date us_stocks intl_stocks bonds real_estate
               commodities balanced cash unmapped].freeze

  # Hand-curated explicit map. Lowercase keys; lookup uppercases the input.
  SYMBOL_MAP = {
    # === US broad equity ===
    'SPY'   => 'us_stocks', 'VOO'   => 'us_stocks', 'IVV'   => 'us_stocks',
    'VTI'   => 'us_stocks', 'ITOT'  => 'us_stocks', 'SCHB'  => 'us_stocks',
    'QQQ'   => 'us_stocks', 'VUG'   => 'us_stocks', 'SCHG'  => 'us_stocks',
    'MGK'   => 'us_stocks', 'IWM'   => 'us_stocks', 'IJR'   => 'us_stocks',
    'IJH'   => 'us_stocks', 'VB'    => 'us_stocks', 'SCHA'  => 'us_stocks',
    'USMV'  => 'us_stocks', 'MTUM'  => 'us_stocks', 'QUAL'  => 'us_stocks',
    'VLUE'  => 'us_stocks', 'FQAL'  => 'us_stocks', 'FVAL'  => 'us_stocks',
    'FELC'  => 'us_stocks', 'FLCSX' => 'us_stocks', 'XLK'   => 'us_stocks',
    'VGT'   => 'us_stocks', 'FTEC'  => 'us_stocks', 'XLF'   => 'us_stocks',
    'VFH'   => 'us_stocks', 'IYF'   => 'us_stocks', 'SCHD'  => 'us_stocks',
    'VYM'   => 'us_stocks', 'HDV'   => 'us_stocks', 'DGRO'  => 'us_stocks',

    # Fidelity VIP variable-insurance funds (mirror the equity counterparts)
    'FXVLT' => 'us_stocks', 'FPDFC' => 'us_stocks', 'FMNDC' => 'us_stocks',

    # Fidelity active large-cap / multi-factor equity funds
    'FMAGX' => 'us_stocks', 'FBGRX' => 'us_stocks', 'FVDFX' => 'us_stocks',
    'FSMD'  => 'us_stocks',

    # Mega-cap individual US stocks the user holds
    'NVDA'  => 'us_stocks', 'AAPL' => 'us_stocks', 'MSFT' => 'us_stocks',
    'GOOGL' => 'us_stocks', 'GOOG' => 'us_stocks', 'AMZN' => 'us_stocks',
    'META'  => 'us_stocks', 'AVGO' => 'us_stocks', 'JPM'  => 'us_stocks',
    'AMAT'  => 'us_stocks', 'MU'   => 'us_stocks', 'GE'   => 'us_stocks',
    'GEV'   => 'us_stocks', 'KLAC' => 'us_stocks', 'XOM'  => 'us_stocks',

    # Foreign individual stocks / ADRs
    'TSM'   => 'intl_stocks', 'SHEL' => 'intl_stocks',

    # === International / emerging ===
    'VXUS'  => 'intl_stocks', 'VEU'   => 'intl_stocks', 'VWO'  => 'intl_stocks',
    'EEM'   => 'intl_stocks', 'IEFA'  => 'intl_stocks', 'IEMG' => 'intl_stocks',
    'FPADX' => 'intl_stocks', 'FEMKX' => 'intl_stocks', 'EFA'  => 'intl_stocks',
    'EMGF'  => 'intl_stocks', 'DFAE'  => 'intl_stocks',
    'FSKLX' => 'intl_stocks', 'FISZX' => 'intl_stocks', 'FVJIC' => 'intl_stocks',

    # === Bonds ===
    'BND'   => 'bonds', 'AGG'   => 'bonds', 'BIV'   => 'bonds',
    'BSV'   => 'bonds', 'VGIT'  => 'bonds', 'VGSH'  => 'bonds',
    'VCIT'  => 'bonds', 'VCSH'  => 'bonds', 'TLT'   => 'bonds',
    'IEF'   => 'bonds', 'VGLT'  => 'bonds', 'EDV'   => 'bonds',
    'LQD'   => 'bonds', 'HYG'   => 'bonds', 'LFEAX' => 'bonds',

    # === Real estate ===
    'VNQ'   => 'real_estate', 'IYR'  => 'real_estate', 'SCHH' => 'real_estate',
    'VNQI'  => 'real_estate',

    # === Commodities ===
    'GLD'   => 'commodities', 'IAU'  => 'commodities', 'SGOL' => 'commodities',
    'GLDM'  => 'commodities', 'SLV'  => 'commodities', 'DBC'  => 'commodities',

    # === Cash ===
    'SPAXX' => 'cash', 'FZFXX' => 'cash', 'FDRXX' => 'cash', 'USD' => 'cash',

    # === Target-date (explicit, common ones) ===
    'FFTHX' => 'target_date', 'TRRJX' => 'target_date'

    # NOTE: balanced funds (FJBAC = VIP Balanced) caught by description regex.
  }.freeze

  # Description regex → class (in priority order — first match wins).
  DESCRIPTION_RULES = [
    # Target-date / glide-path funds (most specific first — must beat both
    # the international and US patterns since "RETIREMENT 2035 INTL" could
    # otherwise misroute).
    [/(FREEDOM|RETIREMENT|TARGET|LIFETIME)\s+\d{4}/i, 'target_date'],
    [/(GLIDE\s*PATH|LIFE\s*PATH)/i,                   'target_date'],

    # ADRs (foreign stock listed on US exchange) — must come BEFORE generic
    # "INC"/"CORP" rules since some ADR descriptors include those words.
    [/(SPON\s+ADS|ADS\s+EA\s+REP|AMERICAN\s+DEPOSITARY|\bADR\b)/i, 'intl_stocks'],

    # International / emerging (check before US so "INTERNATIONAL S&P 500"
    # routes to intl, and to catch broker abbreviations like INTNL/EMNG MKT).
    [/(INTERNATIONAL|\bINTL\b|\bINTNL\b|EMERGING\s*MARKETS?|EMNG\s*MKT|EMRG\s*MKT|EMGR\s+CRE|EX[\s-]?US|TTL\s+INTL|TOTAL\s+INTL|FOREIGN)/i, 'intl_stocks'],

    # US broad / sector / factor equity
    [/S\s*&?\s*P\s*\d{3,4}|S\s*P\s+TOTAL|TOTAL\s+(US\s+)?STOCK|TOTAL\s+MARKET/i, 'us_stocks'],
    [/(LARGE[\s-]CAP|MID[\s-]CAP|SMALL[\s-]CAP|GROWTH\s+(FUND|ETF|INDEX)|VALUE\s+(FUND|ETF|INDEX)|CONTRAFUND|RUSSELL\s*\d{4})/i, 'us_stocks'],
    [/QUALITY\s+FACTOR|VALUE\s+FACTOR|MOMENTUM\s+FACTOR|MIN\s+VOL/i, 'us_stocks'],
    # Active US-equity mutual funds the user holds (and similar)
    [/(MAGELLAN|BLUE\s+CHIP|VALUE\s+DISCOVERY|SML\s+MID|MULTIFACTOR|MLTFCT)/i, 'us_stocks'],

    # Individual US common stocks (description suffixes Fidelity uses).
    # Anything that already matched intl_stocks above (ADRs / international)
    # has bailed out by now, so this is a safe fallback.
    [/(COMMON\s+STOCK|\bCOM\s+NEW\b|\bCAP\s+STK\b|\bINC\s+COM\b|\bCORP\s+COM\b|CORPORATION\s+COM|\bINC\b\s*$|\bCORP\b\s*$|\bCOM\b\s*$|\.COM\s+INC|HOLDINGS\s+INC)/i, 'us_stocks'],

    # Bonds
    [/(BOND|TREASURY|FIXED\s+INCOME|MUNI|MORTGAGE|MBS|HIGH[\s-]YIELD|CORPORATE\s+(NOTE|DEBT)|DEBENTURE|CREDIT)/i, 'bonds'],

    # Real estate
    [/(REAL\s+ESTATE|REIT\b)/i, 'real_estate'],

    # Commodities
    [/(GOLD|SILVER|COMMODIT|PRECIOUS\s+METAL)/i, 'commodities'],

    # Cash / money market
    [/(MONEY\s+MARKET|GOVT?\s+CASH|CORE\s+CASH|CASH\s+RESERVE|US\s+DOLLAR)/i, 'cash'],

    # Balanced (after target-date so year-targeted funds win)
    [/BALANCED/i, 'balanced']
  ].freeze

  module_function

  # Classify a single holding. `description` may be nil. Returns one of CLASSES.
  def classify(symbol:, description: nil)
    sym = symbol.to_s.upcase
    return SYMBOL_MAP[sym] if SYMBOL_MAP.key?(sym)

    desc = description.to_s
    DESCRIPTION_RULES.each do |regex, klass|
      return klass if desc.match?(regex)
    end

    'unmapped'
  end

  # Bucket each position into its class, summing market value per class.
  # Returns an array of:
  #   [{ class:, label:, value:, pct:, count:, symbols: [{symbol:, value:}, ...] }, ...]
  # sorted by value descending. `total_value` is the sum across all positions.
  def breakdown(positions)
    buckets = Hash.new { |h, k| h[k] = { value: 0.0, count: 0, symbols: [] } }
    total = 0.0

    Array(positions).each do |p|
      sym  = (p['symbol'] || p[:symbol]).to_s
      desc = (p['description'] || p[:description]).to_s
      val  = (p['current_value'] || p[:current_value] || p['market_value'] || p[:market_value] ||
              ((p['shares']||p[:shares]).to_f * (p['last_price']||p[:last_price]).to_f)).to_f
      next if val <= 0
      klass = classify(symbol: sym, description: desc)
      buckets[klass][:value] += val
      buckets[klass][:count] += 1
      buckets[klass][:symbols] << { symbol: sym, value: val.round(2) }
      total += val
    end

    rows = buckets.map do |klass, data|
      sorted = data[:symbols].sort_by { |s| -s[:value] }
      {
        class:   klass,
        label:   class_label(klass),
        value:   data[:value].round(2),
        pct:     total.positive? ? (data[:value] / total).round(6) : 0.0,
        count:   data[:count],
        symbols: sorted
      }
    end
    rows.sort_by { |r| -r[:value] }
  end

  # True when the holding is an individual common stock or ADR (NOT a fund)
  # — used by the expense-ratio audit to attribute a 0% drag to stock
  # holdings so coverage % isn't misleadingly low. Detection is the same
  # description-suffix match the classifier already uses for us_stocks /
  # intl_stocks via ADR markers; we expose it as a discrete predicate here
  # so callers don't have to re-implement the regex.
  INDIVIDUAL_STOCK_RULES = [
    # ADRs / foreign-company markers
    /(SPON\s+ADS|ADS\s+EA\s+REP|AMERICAN\s+DEPOSITARY|\bADR\b|NY\s+REGISTRY|ISIN\s*#)/i,
    # Standard US-listed-stock suffixes
    /(COMMON\s+STOCK|\bCOM\s+NEW\b|\bCAP\s+STK\b|\bINC\s+COM\b|\bCORP\s+COM\b|CORPORATION\s+COM|\.COM\s+INC|HOLDINGS\s+INC|INCORPORATED|\bCOM\b)/i,
    # Trailing entity-type words: INC / CORP / CO / PLC / LLC / LTD / NV / AG / SA / CL\s+[A-Z]
    /(\bINC\b|\bCORP\b|\bCO\b|\bPLC\b|\bLLC\b|\bLTD\b)\s*(USD\d|CL\s+[A-Z]|CLASS\s+[A-Z]|COM\s+USD|SHS|ORD|NPV|$)/i
  ].freeze

  def individual_stock?(symbol:, description: nil)
    sym = symbol.to_s.upcase
    # Symbols we explicitly know are individual stocks.
    explicit_stocks = %w[
      NVDA AAPL MSFT GOOGL GOOG AMZN META AVGO JPM AMAT MU GE GEV KLAC XOM TSM SHEL
    ].freeze
    return true if explicit_stocks.include?(sym)
    desc = description.to_s
    INDIVIDUAL_STOCK_RULES.any? { |regex| desc.match?(regex) }
  end

  # Human label for the UI (keeps the data layer's symbol stable, view layer
  # never needs to repeat the label-decoration logic).
  def class_label(klass)
    {
      'target_date' => 'Target-date / glide-path',
      'us_stocks'   => 'US stocks',
      'intl_stocks' => 'International stocks',
      'bonds'       => 'Bonds',
      'real_estate' => 'Real estate',
      'commodities' => 'Commodities',
      'balanced'    => 'Balanced (multi-asset)',
      'cash'        => 'Cash / money market',
      'unmapped'    => 'Unmapped'
    }[klass] || klass
  end
end
