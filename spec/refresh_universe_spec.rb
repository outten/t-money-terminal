require 'rspec'
require 'tmpdir'

ENV['RACK_ENV'] = 'test'

require_relative '../app/refresh_universe'
require_relative '../app/portfolio_store'
require_relative '../app/watchlist_store'
require_relative '../app/symbol_index'

RSpec.describe RefreshUniverse do
  around(:each) do |ex|
    Dir.mktmpdir do |dir|
      ENV['PORTFOLIO_PATH']        = File.join(dir, 'portfolio.json')
      ENV['WATCHLIST_PATH']        = File.join(dir, 'watchlist.json')
      ENV['SYMBOLS_EXTENDED_PATH'] = File.join(dir, 'symbols_extended.json')
      SymbolIndex.reset_extensions!
      ex.run
      SymbolIndex.reset_extensions!
      %w[PORTFOLIO_PATH WATCHLIST_PATH SYMBOLS_EXTENDED_PATH].each { |k| ENV.delete(k) }
    end
  end

  describe '.symbols' do
    it 'always includes every REGIONS symbol' do
      expected = MarketDataService::REGIONS.values.flatten.map(&:upcase).uniq
      expect(RefreshUniverse.symbols).to include(*expected)
    end

    it 'pulls in PortfolioStore holdings' do
      PortfolioStore.add_lot(symbol: 'CMCSA', shares: 10, cost_basis: 100.0)
      expect(RefreshUniverse.symbols).to include('CMCSA')
    end

    it 'pulls in WatchlistStore entries' do
      WatchlistStore.add('PLTR')
      expect(RefreshUniverse.symbols).to include('PLTR')
    end

    it 'omits SymbolIndex extensions by default (avoids stale-reference fan-out)' do
      SymbolIndex.add_extension('FANUY', name: 'Fanuc Corp', region: 'NASDAQ')
      expect(RefreshUniverse.symbols).not_to include('FANUY')
    end

    it 'includes extensions when include_extensions: true' do
      SymbolIndex.add_extension('FANUY', name: 'Fanuc Corp', region: 'NASDAQ')
      expect(RefreshUniverse.symbols(include_extensions: true)).to include('FANUY')
    end

    it 'dedupes when the same symbol appears in multiple sources' do
      WatchlistStore.add('AAPL')                                      # also in REGIONS
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 1, cost_basis: 1)
      list = RefreshUniverse.symbols
      expect(list.count('AAPL')).to eq(1)
    end

    it 'uppercases every symbol' do
      WatchlistStore.add('plTr')
      expect(RefreshUniverse.symbols).to include('PLTR')
      expect(RefreshUniverse.symbols.none? { |s| s != s.upcase }).to be true
    end

    it 'omits the curated list by default (avoids burning provider budget)' do
      # CURATED but not in REGIONS / portfolio / watchlist (e.g. NFLX is curated).
      expect(RefreshUniverse.symbols).not_to include('NFLX')
    end

    it 'includes the curated list when include_curated: true' do
      expect(RefreshUniverse.symbols(include_curated: true)).to include('NFLX')
    end

    it 'drops CUSIP-style entries that sneak in via broker imports' do
      # Fidelity sometimes lands 9-char CUSIPs in the Symbol column.
      allow(PortfolioStore).to receive(:symbols).and_return(['AAPL', '84679Q106', 'NVDA', '20030Q708'])
      list = RefreshUniverse.symbols
      expect(list).to include('AAPL', 'NVDA')
      expect(list).not_to include('84679Q106', '20030Q708')
    end

    it 'survives a transient store error (returns whatever it can)' do
      allow(PortfolioStore).to receive(:symbols).and_raise('boom')
      expect { RefreshUniverse.symbols }.not_to raise_error
      expect(RefreshUniverse.symbols).to include(*MarketDataService::REGIONS.values.flatten.map(&:upcase))
    end
  end

  describe '.categorise' do
    it 'splits ETFs from equities by SYMBOL_TYPES' do
      PortfolioStore.add_lot(symbol: 'CMCSA', shares: 1, cost_basis: 1)  # equity
      cat = RefreshUniverse.categorise
      expect(cat[:etfs]).to    include('SPY', 'QQQ')
      expect(cat[:equity]).to  include('CMCSA', 'AAPL')
      expect(cat[:etfs] & cat[:equity]).to be_empty
    end
  end

  describe '.user_added?' do
    it 'returns false for REGIONS-baked tickers' do
      expect(RefreshUniverse.user_added?('AAPL')).to be false
      expect(RefreshUniverse.user_added?('SPY')).to  be false
    end

    it 'returns true for anything outside REGIONS' do
      expect(RefreshUniverse.user_added?('CMCSA')).to be true
      expect(RefreshUniverse.user_added?('FANUY')).to be true
    end
  end
end
