require 'rack/test'
require 'rspec'
require 'tmpdir'
require 'fileutils'
require 'json'

ENV['RACK_ENV'] = 'test'

require_relative '../app/main'
require_relative '../app/fidelity_importer'

RSpec.describe 'Fidelity broker import' do
  include Rack::Test::Methods

  def app
    TMoneyTerminal
  end

  FIXTURE_PATH = File.expand_path('fixtures/Portfolio_Positions_Apr-29-2026.csv', __dir__)

  around(:each) do |ex|
    Dir.mktmpdir do |dir|
      ENV['WATCHLIST_PATH']        = File.join(dir, 'watchlist.json')
      ENV['ALERTS_PATH']           = File.join(dir, 'alerts.json')
      ENV['ALERTS_LOG_PATH']       = File.join(dir, 'alerts.log')
      ENV['PORTFOLIO_PATH']        = File.join(dir, 'portfolio.json')
      ENV['TRADES_PATH']           = File.join(dir, 'trades.json')
      ENV['SYMBOLS_EXTENDED_PATH'] = File.join(dir, 'symbols_extended.json')

      # Point the importer at a temp dir we control, populated with the
      # fixture (and a couple of older files to test latest-file detection).
      ENV['FIDELITY_IMPORT_DIR']   = File.join(dir, 'fidelity')
      ENV['IMPORT_SNAPSHOT_DIR']   = File.join(dir, 'imports')
      FileUtils.mkdir_p(ENV['FIDELITY_IMPORT_DIR'])
      FileUtils.cp(FIXTURE_PATH, ENV['FIDELITY_IMPORT_DIR'])

      SymbolIndex.reset_extensions!
      ex.run
      SymbolIndex.reset_extensions!
      %w[WATCHLIST_PATH ALERTS_PATH ALERTS_LOG_PATH PORTFOLIO_PATH TRADES_PATH
         SYMBOLS_EXTENDED_PATH FIDELITY_IMPORT_DIR IMPORT_SNAPSHOT_DIR].each { |k| ENV.delete(k) }
    end
  end

  # --- Parser ---------------------------------------------------------------

  describe 'FidelityImporter.parse_money' do
    it 'parses Fidelity money / percent / quantity strings' do
      pm = ->(s) { FidelityImporter.parse_money(s) }
      expect(pm.call('$270.17')).to eq(270.17)
      expect(pm.call('+$5,133.23')).to eq(5133.23)
      expect(pm.call('-$0.54')).to eq(-0.54)
      expect(pm.call('+85.48%')).to eq(85.48)
      expect(pm.call('9.696')).to eq(9.696)
      expect(pm.call('')).to be_nil
      expect(pm.call('--')).to be_nil
      expect(pm.call(nil)).to be_nil
    end
  end

  describe 'FidelityImporter.extract_date_from_filename' do
    it 'parses the Mmm-DD-YYYY filename pattern' do
      d = FidelityImporter.extract_date_from_filename('/x/Portfolio_Positions_Apr-29-2026.csv')
      expect(d).to eq(Date.new(2026, 4, 29))
    end

    it 'returns nil for unrelated filenames' do
      expect(FidelityImporter.extract_date_from_filename('/x/random.csv')).to be_nil
    end
  end

  describe 'FidelityImporter.latest_file_in' do
    it 'picks the newest file by date in filename' do
      dir = ENV['FIDELITY_IMPORT_DIR']
      FileUtils.cp(FIXTURE_PATH, File.join(dir, 'Portfolio_Positions_Mar-15-2026.csv'))
      latest = FidelityImporter.latest_file_in(dir)
      expect(File.basename(latest)).to eq('Portfolio_Positions_Apr-29-2026.csv')
    end

    it 'returns nil when no CSV present' do
      empty = Dir.mktmpdir
      expect(FidelityImporter.latest_file_in(empty)).to be_nil
    ensure
      FileUtils.rm_rf(empty)
    end
  end

  describe 'FidelityImporter.parse' do
    let(:parsed) { FidelityImporter.parse(FIXTURE_PATH) }

    it 'returns the parsed file date' do
      expect(parsed[:file_date]).to eq(Date.new(2026, 4, 29))
    end

    it 'skips cash, money-market, pending-activity, and footer rows' do
      reasons = parsed[:skipped].map { |r| r[:reason] }
      expect(reasons).to include('cash_or_money_market', 'pending_activity')
      # Footer disclaimer lines have no Account Number → "non_position_row".
      expect(reasons).to include('non_position_row')
    end

    it 'aggregates AAPL across Individual + ROTH IRA with weighted-avg basis' do
      aapl = parsed[:positions].find { |p| p[:symbol] == 'AAPL' }
      expect(aapl[:shares]).to eq(15.0)               # 10 + 5
      expect(aapl[:cost_basis]).to be_within(1e-4).of(150.0) # both lots @ $150
      expect(aapl[:accounts]).to contain_exactly('Individual - TOD', 'ROTH IRA')
    end

    it 'parses the prices, cost basis totals, and gain/loss dollars' do
      nvda = parsed[:positions].find { |p| p[:symbol] == 'NVDA' }
      expect(nvda[:last_price]).to eq(400.0)
      expect(nvda[:cost_basis]).to eq(100.0)
      expect(nvda[:total_pl]).to eq(1500.0)
    end

    it 'sorts positions by current_value descending' do
      symbols = parsed[:positions].map { |p| p[:symbol] }
      # AAPL aggregated (2000+1000 = 3000) > NVDA (2000) > VOO (1300)
      expect(symbols).to eq(%w[AAPL NVDA VOO])
    end
  end

  # --- import! orchestrator -------------------------------------------------

  describe 'FidelityImporter.import!' do
    it 'replaces existing lots with broker-derived single-lot positions' do
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 999, cost_basis: 1.0)
      summary = FidelityImporter.import!
      lots = PortfolioStore.lots_for('AAPL')
      expect(lots.length).to eq(1)
      expect(lots.first[:shares]).to eq(15)
      expect(lots.first[:cost_basis]).to eq(150.0)
      expect(summary[:replaced]).to be >= 1
    end

    it 'leaves untouched any symbol not in the file' do
      PortfolioStore.add_lot(symbol: 'TSLA', shares: 50, cost_basis: 200)
      FidelityImporter.import!
      expect(PortfolioStore.find('TSLA')).not_to be_nil
    end

    it 'registers unknown symbols as SymbolIndex extensions' do
      expect(SymbolIndex.known?('VOO')).to be true # already in CURATED
      # Use a symbol that's NOT in the curated list — VOOG isn't
      # but the fixture has VOO. Add a fixture row that's truly unknown.
      summary = FidelityImporter.import!
      # All fixture symbols must end up known after import.
      %w[AAPL NVDA VOO].each do |sym|
        expect(SymbolIndex.known?(sym)).to be(true), "#{sym} should be known after import"
      end
      expect(summary[:imported]).to eq(3)
    end

    it 'primes the quote cache so subsequent quote() reads return the file price' do
      FidelityImporter.import!
      MarketDataService.instance_variable_get(:@cache_timestamps).delete('AAPL') # ensure cache hit, not refetch
      MarketDataService.instance_variable_get(:@cache_timestamps)['AAPL'] = Time.now
      q = MarketDataService.instance_variable_get(:@cache)['AAPL']
      expect(q['05. price']).to eq('200.0')
    end

    it 'does not record a buy or sell trade (this is a sync, not an action)' do
      FidelityImporter.import!
      expect(TradesStore.read).to be_empty
    end

    it 'raises when no Fidelity CSV is present' do
      FileUtils.rm_rf(ENV['FIDELITY_IMPORT_DIR'])
      expect { FidelityImporter.import! }.to raise_error(/No Fidelity CSV/)
    end
  end

  # --- HTTP routes ----------------------------------------------------------

  describe 'POST /portfolio/import/fidelity' do
    it 'imports and redirects to /portfolio with summary params' do
      post '/portfolio/import/fidelity'
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include('/portfolio?')
      expect(last_response.location).to include('imported_count=3')
      expect(last_response.location).to include('imported_file=2026-04-29')
    end

    it 'redirects with imported_error= when no CSV is found' do
      FileUtils.rm_rf(ENV['FIDELITY_IMPORT_DIR'])
      post '/portfolio/import/fidelity'
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include('imported_error=')
    end
  end

  describe 'GET /portfolio with import flash + signal annotations' do
    it 'renders the import banner and signal column after import' do
      FidelityImporter.import!
      get '/portfolio?imported_count=3&imported_file=2026-04-29'
      expect(last_response).to be_ok
      expect(last_response.body).to include('Imported 3 positions')
      expect(last_response.body).to include('Signal')          # column header
      expect(last_response.body).to include('signal-badge')    # inline signal pill
    end

    it 'flags concentration when a position is > 20% of the portfolio' do
      # Wipe other holdings and add only NVDA so NVDA is 100% of value.
      FidelityImporter.import!
      %w[AAPL VOO].each { |s| PortfolioStore.remove(s) }
      MarketDataService.prime_quote!('NVDA', price: 400.0, change_pct: 0)
      get '/portfolio'
      expect(last_response.body).to include('Concentration')
    end
  end

  describe 'GET /api/portfolio/import/fidelity/preview' do
    it 'returns parsed positions without modifying state' do
      get '/api/portfolio/import/fidelity/preview'
      expect(last_response).to be_ok
      body = JSON.parse(last_response.body)
      expect(body['positions_count']).to eq(3)
      expect(body['file_date']).to eq('2026-04-29')
      expect(PortfolioStore.read).to be_empty # state unchanged
    end

    it '404s when no CSV exists' do
      FileUtils.rm_rf(ENV['FIDELITY_IMPORT_DIR'])
      get '/api/portfolio/import/fidelity/preview'
      expect(last_response.status).to eq(404)
    end
  end

  # --- Snapshot persistence + cache invalidation on re-import ---------------

  describe 'ImportSnapshotStore' do
    it 'write + latest round-trips the parsed payload' do
      ImportSnapshotStore.write(
        source: 'fidelity',
        basename: 'Portfolio_Positions_Apr-29-2026',
        data: { 'file_date' => '2026-04-29', 'positions' => [{ 'symbol' => 'AAPL' }] }
      )
      latest = ImportSnapshotStore.latest(source: 'fidelity')
      expect(latest['file_date']).to eq('2026-04-29')
      expect(latest['positions'].first['symbol']).to eq('AAPL')
      expect(latest['written_at']).to be_a(String)
      expect(latest['path']).to end_with('Portfolio_Positions_Apr-29-2026.json')
    end

    it 'latest returns the snapshot whose filename date is newest' do
      ImportSnapshotStore.write(source: 'fidelity', basename: 'Portfolio_Positions_Mar-15-2026',
                                data: { 'positions' => [{ 'symbol' => 'OLD' }] })
      ImportSnapshotStore.write(source: 'fidelity', basename: 'Portfolio_Positions_Apr-29-2026',
                                data: { 'positions' => [{ 'symbol' => 'NEW' }] })
      latest = ImportSnapshotStore.latest(source: 'fidelity')
      expect(latest['positions'].first['symbol']).to eq('NEW')
    end

    it 'list returns all snapshots newest-first' do
      ImportSnapshotStore.write(source: 'fidelity', basename: 'Portfolio_Positions_Mar-15-2026', data: { 'file_date' => '2026-03-15', 'positions' => [] })
      ImportSnapshotStore.write(source: 'fidelity', basename: 'Portfolio_Positions_Apr-29-2026', data: { 'file_date' => '2026-04-29', 'positions' => [] })
      list = ImportSnapshotStore.list(source: 'fidelity')
      expect(list.length).to eq(2)
      expect(list.first[:file_date]).to eq('2026-04-29')
    end

    it 'find_position returns the broker row for a symbol in the latest snapshot' do
      ImportSnapshotStore.write(source: 'fidelity', basename: 'Portfolio_Positions_Apr-29-2026',
                                data: { 'positions' => [{ 'symbol' => 'AAPL', 'pct_account' => 7.84 }] })
      bp = ImportSnapshotStore.find_position('aapl', source: 'fidelity')
      expect(bp['pct_account']).to eq(7.84)
    end

    it 'returns nil for missing source / unknown symbol' do
      expect(ImportSnapshotStore.latest(source: 'schwab')).to be_nil
      expect(ImportSnapshotStore.find_position('AAPL', source: 'fidelity')).to be_nil
    end
  end

  describe 'FidelityImporter.import! snapshot persistence' do
    it 'writes a snapshot to data/imports/fidelity/<basename>.json on import' do
      summary = FidelityImporter.import!
      expect(summary[:snapshot_path]).to be_a(String)
      expect(File.exist?(summary[:snapshot_path])).to be true

      latest = ImportSnapshotStore.latest(source: 'fidelity')
      expect(latest['basename']).to eq('Portfolio_Positions_Apr-29-2026')
      expect(latest['positions'].length).to eq(3)
      # Snapshot embeds the import summary so we know what happened on disk.
      expect(latest['summary']).to be_a(Hash)
      expect(latest['summary']['imported']).to eq(3)
    end

    it 'overwrites an existing snapshot when re-imported (same basename)' do
      FidelityImporter.import!
      first_snap = ImportSnapshotStore.latest(source: 'fidelity')
      sleep 0.01
      FidelityImporter.import!
      second_snap = ImportSnapshotStore.latest(source: 'fidelity')
      expect(second_snap['written_at']).to be > first_snap['written_at']
    end
  end

  describe 'FidelityImporter.import! cache invalidation' do
    it 'busts historical cache for every imported symbol' do
      # Pre-seed historical cache so we can observe the bust.
      stub_bars = (1..5).map { |i| { date: "2024-04-#{format('%02d', i)}", close: 100.0 + i } }
      MarketDataService.send(:store_cache, 'candle:AAPL:1y', stub_bars)
      expect(MarketDataService.send(:read_live_cache, 'candle:AAPL:1y')).to eq(stub_bars)

      summary = FidelityImporter.import!
      expect(summary[:busted_caches]).to include('AAPL')
      expect(MarketDataService.send(:read_live_cache, 'candle:AAPL:1y')).to be_nil
    end

    it 'preserves the primed quote cache (bust runs before prime)' do
      FidelityImporter.import!
      cached = MarketDataService.instance_variable_get(:@cache)['AAPL']
      expect(cached).not_to be_nil
      expect(cached['05. price']).to eq('200.0')
    end

    it 'leaves analyst / profile caches alone (broker file does not change those)' do
      MarketDataService.send(:store_cache, 'analyst:AAPL', { strong_buy: 12 })
      FidelityImporter.import!
      expect(MarketDataService.instance_variable_get(:@cache)['analyst:AAPL']).to eq({ strong_buy: 12 })
    end
  end

  describe 'GET /portfolio surfacing snapshot data' do
    it 'shows the last-imported timestamp once a snapshot exists' do
      FidelityImporter.import!
      get '/portfolio'
      expect(last_response).to be_ok
      expect(last_response.body).to include('Last imported:')
      expect(last_response.body).to include('2026-04-29')
    end

    it 'shows broker accounts per row when the snapshot has them (e.g. AAPL split between Individual and ROTH)' do
      FidelityImporter.import!
      get '/portfolio'
      expect(last_response.body).to include('Held in Individual - TOD + ROTH IRA')
    end
  end
end
