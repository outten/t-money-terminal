require 'set'
require 'json'
require 'fileutils'
require 'time'
require_relative 'market_data_service'

# SymbolIndex — the universe of tickers the app knows about.
#
# Two layers:
#   1. CURATED + REGIONS — baked-in list (~55 symbols) that ships with the app.
#   2. Runtime extensions persisted to `data/symbols_extended.json` — symbols
#      the user discovered via search. Format:
#        [{ symbol:, name:, region:, source:, added_at: }, ...]
#
# Used by:
#   • `/api/symbols` — feeds the top-nav search box with {symbol, name, region}
#   • `SymbolIndex.known?(symbol)` — whitelist for /analysis/:symbol and /api
#
# Symbols are added via `SymbolIndex.add_extension(...)` (call-site validates
# whatever it likes; the index just persists). The discovery flow lives in
# `app/main.rb` route `POST /api/symbols/discover`, which calls
# `MarketDataService.quote(symbol)` and only persists on a successful quote.
module SymbolIndex
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

  DEFAULT_EXTENSIONS_PATH = File.expand_path('../../data/symbols_extended.json', __FILE__)
  MUTEX = Mutex.new

  # Symbols matching this pattern are eligible for discovery (US tickers + ETFs
  # + share classes). Avoids accepting random user input as a ticker.
  TICKER_PATTERN = /\A[A-Z][A-Z0-9.\-]{0,9}\z/.freeze

  module_function

  def extensions_path
    ENV['SYMBOLS_EXTENDED_PATH'] || DEFAULT_EXTENSIONS_PATH
  end

  # Returns the persisted extension list as [[symbol, name, region], ...]
  # so it can drop straight into `all`. Cached per-process; invalidated on add.
  def extensions
    @extensions ||= load_extensions
  end

  # Combined list of [symbol, name, region] covering REGIONS + CURATED + extensions.
  # Curated and extensions both win over REGIONS on duplicate symbols.
  def all
    @all ||= begin
      region_rows = MarketDataService::REGIONS.flat_map do |rkey, symbols|
        region = REGION_FOR_REGION_KEY[rkey] || rkey.to_s
        symbols.map { |s| [s, REGION_SYMBOL_NAMES[s] || s, region] }
      end
      # Order matters for `uniq` — extensions and curated should override region
      # rows if a duplicate ever appears.
      (region_rows + CURATED + extensions).uniq { |row| row[0] }
    end
  end

  def symbols
    @symbols ||= all.map(&:first)
  end

  def to_a
    all.map { |s, n, r| { symbol: s, name: n, region: r } }
  end

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

  def known?(symbol)
    symbol_set.include?(symbol.to_s.upcase)
  end

  # Loose validity check for "things a user might want to discover as a ticker"
  # — used to early-reject obvious garbage before hitting any provider.
  def looks_like_ticker?(query)
    s = query.to_s.strip.upcase
    !s.empty? && TICKER_PATTERN.match?(s)
  end

  # Append `symbol` to the runtime extension store and invalidate caches so
  # subsequent search/known? calls see it. Returns the merged extension hash.
  # No-op + returns the existing entry if the symbol is already known.
  def add_extension(symbol, name: nil, region: nil, source: nil)
    sym = symbol.to_s.strip.upcase
    raise ArgumentError, 'symbol required' if sym.empty?

    MUTEX.synchronize do
      list = read_extensions_unlocked
      existing = list.find { |row| row[:symbol] == sym }
      return existing if existing

      entry = {
        symbol:   sym,
        name:     name.to_s.empty? ? sym : name.to_s,
        region:   region.to_s.empty? ? 'Other' : region.to_s,
        source:   source,
        added_at: Time.now.utc.iso8601
      }
      list << entry
      write_extensions_unlocked(list)
      invalidate_caches!
      entry
    end
  end

  # Test helper — also clears the on-disk extension store. Production code
  # never calls this.
  def reset_extensions!
    MUTEX.synchronize do
      File.delete(extensions_path) if File.exist?(extensions_path)
      invalidate_caches!
    end
  end

  def symbol_set
    @symbol_set ||= symbols.to_set
  end

  # --- internals -----------------------------------------------------------

  def invalidate_caches!
    @extensions = nil
    @all        = nil
    @symbols    = nil
    @symbol_set = nil
  end

  def load_extensions
    raw = File.exist?(extensions_path) ? File.read(extensions_path) : nil
    return [] unless raw && !raw.strip.empty?
    parsed = JSON.parse(raw)
    return [] unless parsed.is_a?(Array)
    parsed.filter_map do |row|
      next unless row.is_a?(Hash) && row['symbol']
      [row['symbol'].to_s.upcase, row['name'].to_s, row['region'].to_s]
    end
  rescue JSON::ParserError
    []
  end

  def read_extensions_unlocked
    return [] unless File.exist?(extensions_path)
    raw = File.read(extensions_path)
    return [] if raw.strip.empty?
    parsed = JSON.parse(raw)
    return [] unless parsed.is_a?(Array)
    parsed.map { |h| h.transform_keys(&:to_sym) }
  rescue JSON::ParserError
    []
  end

  def write_extensions_unlocked(list)
    FileUtils.mkdir_p(File.dirname(extensions_path))
    tmp = "#{extensions_path}.tmp"
    File.write(tmp, JSON.pretty_generate(list))
    File.rename(tmp, extensions_path)
  end
end
