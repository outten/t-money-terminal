require 'set'
require_relative 'market_data_service'

# SymbolIndex — the universe of tickers the app knows about.
#
# Used by:
#   • `/api/symbols` — feeds the top-nav search box with {symbol, name, region}
#   • `TMoneyTerminal::VALID_SYMBOLS` — whitelist for /analysis/:symbol and /api
#
# Sourced from MarketDataService::REGIONS + a curated list of large-cap US
# names so the search box is useful without depending on a third-party API.
# The list can be extended freely — as long as a symbol is quotable by Tiingo,
# Alpha Vantage, Finnhub, or Yahoo the waterfall in MarketDataService will
# resolve it.
module SymbolIndex
  # Curated extras beyond what REGIONS provides. Format: [symbol, name, region].
  CURATED = [
    # US large-caps
    ['TSLA',  'Tesla, Inc.',                    'US'],
    ['META',  'Meta Platforms, Inc.',           'US'],
    ['NFLX',  'Netflix, Inc.',                  'US'],
    ['AMD',   'Advanced Micro Devices',         'US'],
    ['INTC',  'Intel Corporation',              'US'],
    ['ORCL',  'Oracle Corporation',             'US'],
    ['CRM',   'Salesforce, Inc.',               'US'],
    ['ADBE',  'Adobe Inc.',                     'US'],
    ['PYPL',  'PayPal Holdings',                'US'],
    ['DIS',   'Walt Disney Co.',                'US'],
    ['KO',    'Coca-Cola Company',              'US'],
    ['PEP',   'PepsiCo, Inc.',                  'US'],
    ['WMT',   'Walmart Inc.',                   'US'],
    ['COST',  'Costco Wholesale',               'US'],
    ['HD',    'Home Depot',                     'US'],
    ['MCD',   'McDonald\'s Corporation',        'US'],
    ['NKE',   'Nike, Inc.',                     'US'],
    ['V',     'Visa Inc.',                      'US'],
    ['MA',    'Mastercard Incorporated',        'US'],
    ['BAC',   'Bank of America Corp.',          'US'],
    ['WFC',   'Wells Fargo & Co.',              'US'],
    ['GS',    'Goldman Sachs Group',            'US'],
    ['MS',    'Morgan Stanley',                 'US'],
    ['BRK.B', 'Berkshire Hathaway Class B',     'US'],
    ['JNJ',   'Johnson & Johnson',              'US'],
    ['PFE',   'Pfizer Inc.',                    'US'],
    ['UNH',   'UnitedHealth Group',             'US'],
    ['XOM',   'Exxon Mobil Corp.',              'US'],
    ['CVX',   'Chevron Corporation',            'US'],
    ['BA',    'Boeing Company',                 'US'],
    ['CAT',   'Caterpillar Inc.',               'US'],
    ['GE',    'General Electric',               'US'],
    ['F',     'Ford Motor Company',             'US'],
    # ETFs
    ['VOO',   'Vanguard S&P 500 ETF',           'US'],
    ['VTI',   'Vanguard Total Stock Market',    'US'],
    ['IWM',   'iShares Russell 2000',           'US'],
    ['DIA',   'SPDR Dow Jones ETF',             'US'],
    ['GLD',   'SPDR Gold Shares',               'US'],
    ['TLT',   'iShares 20+ Yr Treasury',        'US'],
    ['XLK',   'Technology Select Sector SPDR',  'US'],
    ['XLF',   'Financial Select Sector SPDR',   'US'],
    ['XLE',   'Energy Select Sector SPDR',      'US']
  ].freeze

  # Names for the symbols that already live in MarketDataService::REGIONS.
  REGION_SYMBOL_NAMES = {
    'SPY'   => 'SPDR S&P 500 ETF',
    'QQQ'   => 'Invesco QQQ Trust',
    'AAPL'  => 'Apple Inc.',
    'MSFT'  => 'Microsoft Corporation',
    'GOOGL' => 'Alphabet Inc. Class A',
    'AMZN'  => 'Amazon.com, Inc.',
    'NVDA'  => 'NVIDIA Corporation',
    'JPM'   => 'JPMorgan Chase & Co.',
    'EWJ'   => 'iShares MSCI Japan ETF',
    'TM'    => 'Toyota Motor Corporation',
    'SONY'  => 'Sony Group Corporation',
    'VGK'   => 'Vanguard FTSE Europe ETF',
    'ASML'  => 'ASML Holding N.V.',
    'SAP'   => 'SAP SE',
    'BP'    => 'BP p.l.c.'
  }.freeze

  REGION_FOR_REGION_KEY = {
    us:     'US',
    japan:  'Japan',
    europe: 'Europe'
  }.freeze

  module_function

  # Combined list of [symbol, name, region] covering REGIONS + CURATED.
  # CURATED entries win if they duplicate (shouldn't happen in practice).
  def all
    @all ||= begin
      region_rows = MarketDataService::REGIONS.flat_map do |rkey, symbols|
        region = REGION_FOR_REGION_KEY[rkey] || rkey.to_s
        symbols.map { |s| [s, REGION_SYMBOL_NAMES[s] || s, region] }
      end
      (region_rows + CURATED).uniq { |row| row[0] }
    end
  end

  # Flat array of every symbol the search bar can jump to.
  def symbols
    @symbols ||= all.map(&:first).freeze
  end

  # `[{symbol:, name:, region:}, ...]` JSON-friendly shape for /api/symbols.
  def to_a
    all.map { |s, n, r| { symbol: s, name: n, region: r } }
  end

  # Case-insensitive prefix + substring search across symbol and name, ranked:
  #   1) exact symbol match    2) symbol prefix    3) name prefix    4) substring
  def search(query, limit: 10)
    q = query.to_s.strip.upcase
    return [] if q.empty?

    scored = all.filter_map do |symbol, name, region|
      sym_up  = symbol.upcase
      name_up = name.upcase

      score =
        if    sym_up == q                       then 0
        elsif sym_up.start_with?(q)             then 1
        elsif name_up.start_with?(q)            then 2
        elsif sym_up.include?(q)                then 3
        elsif name_up.include?(q)               then 4
        else nil
        end

      score && [score, symbol, name, region]
    end

    scored.sort_by { |row| [row[0], row[1]] }
          .first(limit)
          .map { |_score, symbol, name, region| { symbol: symbol, name: name, region: region } }
  end

  # O(1) membership check for VALID_SYMBOLS.
  def known?(symbol)
    symbol_set.include?(symbol.to_s.upcase)
  end

  def symbol_set
    @symbol_set ||= symbols.to_set
  end
end

