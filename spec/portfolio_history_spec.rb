require 'rack/test'
require 'rspec'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'date'

ENV['RACK_ENV'] = 'test'

require_relative '../app/main'
require_relative '../app/portfolio_history'
require_relative '../app/import_snapshot_store'
require_relative '../app/fidelity_importer'

RSpec.describe 'PortfolioHistory + backfill + /portfolio history' do
  include Rack::Test::Methods

  def app
    TMoneyTerminal
  end

  around(:each) do |ex|
    Dir.mktmpdir do |dir|
      ENV['IMPORT_SNAPSHOT_DIR']   = File.join(dir, 'imports')
      ENV['FIDELITY_IMPORT_DIR']   = File.join(dir, 'porfolio', 'fidelity')
      ENV['PORTFOLIO_PATH']        = File.join(dir, 'portfolio.json')
      ENV['TRADES_PATH']           = File.join(dir, 'trades.json')
      ENV['SYMBOLS_EXTENDED_PATH'] = File.join(dir, 'symbols_extended.json')
      ENV['WATCHLIST_PATH']        = File.join(dir, 'watchlist.json')
      ENV['ALERTS_PATH']           = File.join(dir, 'alerts.json')
      ENV['PROFILE_PATH']          = File.join(dir, 'profile.json')
      SymbolIndex.reset_extensions! if defined?(SymbolIndex) && SymbolIndex.respond_to?(:reset_extensions!)
      ex.run
      SymbolIndex.reset_extensions! if defined?(SymbolIndex) && SymbolIndex.respond_to?(:reset_extensions!)
      %w[IMPORT_SNAPSHOT_DIR FIDELITY_IMPORT_DIR PORTFOLIO_PATH TRADES_PATH
         SYMBOLS_EXTENDED_PATH WATCHLIST_PATH ALERTS_PATH PROFILE_PATH].each { |k| ENV.delete(k) }
    end
  end

  def write_snapshot(file_date, positions)
    ImportSnapshotStore.write(
      source:   'fidelity',
      basename: "Portfolio_Positions_#{Date.parse(file_date).strftime('%b-%d-%Y')}",
      data:     {
        'file_date' => file_date,
        'positions' => positions
      }
    )
  end

  describe PortfolioHistory do
    describe '.time_series' do
      it 'returns [] when there are no snapshots' do
        expect(PortfolioHistory.time_series).to eq([])
      end

      it 'returns one row per snapshot, oldest-first, with day_change/day_change_pct' do
        write_snapshot('2026-04-28', [
          { 'symbol' => 'AAPL', 'shares' => 10, 'cost_basis' => 100, 'last_price' => 110, 'current_value' => 1100, 'cost_value' => 1000 }
        ])
        write_snapshot('2026-04-29', [
          { 'symbol' => 'AAPL', 'shares' => 10, 'cost_basis' => 100, 'last_price' => 115, 'current_value' => 1150, 'cost_value' => 1000 }
        ])
        write_snapshot('2026-04-30', [
          { 'symbol' => 'AAPL', 'shares' => 10, 'cost_basis' => 100, 'last_price' => 105, 'current_value' => 1050, 'cost_value' => 1000 }
        ])
        out = PortfolioHistory.time_series
        expect(out.map { |r| r[:date] }).to eq(%w[2026-04-28 2026-04-29 2026-04-30])
        expect(out[0][:total_value]).to eq(1100.0)
        expect(out[0][:day_change]).to be_nil
        expect(out[1][:total_value]).to eq(1150.0)
        expect(out[1][:day_change]).to eq(50.0)
        expect(out[1][:day_change_pct]).to be_within(1e-6).of(50.0 / 1100.0)
        expect(out[2][:day_change]).to eq(-100.0)
        expect(out[2][:total_value]).to eq(1050.0)
      end

      it 'falls back to shares × last_price when current_value is missing' do
        write_snapshot('2026-04-28', [
          { 'symbol' => 'X', 'shares' => 10, 'cost_basis' => 100, 'last_price' => 110 }
        ])
        out = PortfolioHistory.time_series
        expect(out.first[:total_value]).to eq(1100.0)
      end

      it 'sums multiple positions per snapshot' do
        write_snapshot('2026-04-28', [
          { 'symbol' => 'A', 'shares' => 10, 'cost_basis' => 50, 'last_price' => 100, 'current_value' => 1000, 'cost_value' => 500 },
          { 'symbol' => 'B', 'shares' => 5,  'cost_basis' => 200, 'last_price' => 250, 'current_value' => 1250, 'cost_value' => 1000 }
        ])
        out = PortfolioHistory.time_series
        expect(out.first[:total_value]).to eq(2250.0)
        expect(out.first[:total_cost]).to eq(1500.0)
        expect(out.first[:unrealized_pl]).to eq(750.0)
      end

      it 'skips snapshots with empty file_date' do
        ImportSnapshotStore.write(source: 'fidelity', basename: 'no_date',
                                  data: { 'file_date' => '', 'positions' => [{ 'symbol' => 'A', 'shares' => 1, 'last_price' => 1 }] })
        write_snapshot('2026-04-28', [{ 'symbol' => 'A', 'shares' => 1, 'cost_basis' => 1, 'last_price' => 1 }])
        out = PortfolioHistory.time_series
        expect(out.length).to eq(1)
      end
    end

    describe '.per_symbol_series' do
      it 'pivots snapshots into a per-symbol history sorted oldest-first' do
        write_snapshot('2026-04-28', [
          { 'symbol' => 'A', 'shares' => 10, 'cost_basis' => 50, 'last_price' => 100, 'current_value' => 1000 },
          { 'symbol' => 'B', 'shares' => 5,  'cost_basis' => 200, 'last_price' => 250, 'current_value' => 1250 }
        ])
        write_snapshot('2026-04-29', [
          { 'symbol' => 'A', 'shares' => 10, 'cost_basis' => 50, 'last_price' => 110, 'current_value' => 1100 }
        ])
        out = PortfolioHistory.per_symbol_series
        expect(out['A'].map { |r| r[:date] }).to eq(%w[2026-04-28 2026-04-29])
        expect(out['A'].map { |r| r[:market_value] }).to eq([1000.0, 1100.0])
        expect(out['B'].length).to eq(1)
      end

      it 'upcases symbols' do
        write_snapshot('2026-04-28', [{ 'symbol' => 'aapl', 'shares' => 1, 'last_price' => 1, 'current_value' => 1 }])
        out = PortfolioHistory.per_symbol_series
        expect(out.keys).to include('AAPL')
      end
    end

    describe '.series_for' do
      it 'returns the trajectory of one symbol oldest-first' do
        write_snapshot('2026-04-28', [{ 'symbol' => 'A', 'shares' => 10, 'last_price' => 100, 'current_value' => 1000 }])
        write_snapshot('2026-04-29', [{ 'symbol' => 'A', 'shares' => 10, 'last_price' => 110, 'current_value' => 1100 }])
        out = PortfolioHistory.series_for('A')
        expect(out.length).to eq(2)
        expect(out.first[:date]).to eq('2026-04-28')
      end

      it 'returns empty when symbol never appeared' do
        write_snapshot('2026-04-28', [{ 'symbol' => 'A', 'shares' => 10, 'last_price' => 100, 'current_value' => 1000 }])
        expect(PortfolioHistory.series_for('Z')).to eq([])
      end
    end

    describe '.underwater_streak' do
      it 'returns nil for a symbol with no history' do
        expect(PortfolioHistory.underwater_streak('NOPE')).to be_nil
      end

      it 'returns nil when the latest snapshot is in the green' do
        write_snapshot('2026-04-28', [{ 'symbol' => 'A', 'shares' => 10, 'cost_basis' => 100, 'last_price' => 90, 'current_value' => 900, 'cost_value' => 1000 }])
        write_snapshot('2026-04-29', [{ 'symbol' => 'A', 'shares' => 10, 'cost_basis' => 100, 'last_price' => 110, 'current_value' => 1100, 'cost_value' => 1000 }])
        expect(PortfolioHistory.underwater_streak('A')).to be_nil
      end

      it 'counts consecutive red snapshots ending at the latest' do
        write_snapshot('2026-04-26', [{ 'symbol' => 'A', 'shares' => 10, 'cost_basis' => 100, 'last_price' => 110, 'current_value' => 1100, 'cost_value' => 1000 }])
        write_snapshot('2026-04-27', [{ 'symbol' => 'A', 'shares' => 10, 'cost_basis' => 100, 'last_price' => 95,  'current_value' => 950,  'cost_value' => 1000 }])
        write_snapshot('2026-04-28', [{ 'symbol' => 'A', 'shares' => 10, 'cost_basis' => 100, 'last_price' => 92,  'current_value' => 920,  'cost_value' => 1000 }])
        write_snapshot('2026-04-29', [{ 'symbol' => 'A', 'shares' => 10, 'cost_basis' => 100, 'last_price' => 88,  'current_value' => 880,  'cost_value' => 1000 }])
        out = PortfolioHistory.underwater_streak('A')
        expect(out[:snapshots]).to eq(3)
        expect(out[:since]).to eq('2026-04-27')
        expect(out[:currently_underwater]).to eq(true)
      end

      it 'breaks the streak on the first non-red snapshot working backwards' do
        write_snapshot('2026-04-25', [{ 'symbol' => 'A', 'shares' => 10, 'cost_basis' => 100, 'last_price' => 80, 'current_value' => 800, 'cost_value' => 1000 }])
        write_snapshot('2026-04-26', [{ 'symbol' => 'A', 'shares' => 10, 'cost_basis' => 100, 'last_price' => 105, 'current_value' => 1050, 'cost_value' => 1000 }])
        write_snapshot('2026-04-27', [{ 'symbol' => 'A', 'shares' => 10, 'cost_basis' => 100, 'last_price' => 95, 'current_value' => 950, 'cost_value' => 1000 }])
        out = PortfolioHistory.underwater_streak('A')
        expect(out[:snapshots]).to eq(1)
        expect(out[:since]).to eq('2026-04-27')
      end

      it 'accepts a pre-loaded series array' do
        series = [
          { date: '2026-04-26', market_value: 950.0, cost_value: 1000.0 },
          { date: '2026-04-27', market_value: 940.0, cost_value: 1000.0 }
        ]
        out = PortfolioHistory.underwater_streak(series)
        expect(out[:snapshots]).to eq(2)
        expect(out[:since]).to eq('2026-04-26')
      end
    end

    describe '.sparkline_svg' do
      it 'returns an em-dash for fewer than 2 points' do
        expect(PortfolioHistory.sparkline_svg([])).to include('—')
        expect(PortfolioHistory.sparkline_svg([{ market_value: 1.0 }])).to include('—')
      end

      it 'colours green when last >= first' do
        svg = PortfolioHistory.sparkline_svg([{ market_value: 100 }, { market_value: 110 }])
        expect(svg).to include('#0a8a3a')
      end

      it 'colours red when last < first' do
        svg = PortfolioHistory.sparkline_svg([{ market_value: 110 }, { market_value: 100 }])
        expect(svg).to include('#b00020')
      end

      it 'survives a flat series without divide-by-zero' do
        svg = PortfolioHistory.sparkline_svg([{ market_value: 100 }, { market_value: 100 }])
        expect(svg).to include('<polyline')
        expect(svg).not_to include('NaN')
      end
    end
  end

  describe FidelityImporter do
    let(:input_dir)  { ENV['FIDELITY_IMPORT_DIR'] }
    let(:output_dir) { File.join(ENV['IMPORT_SNAPSHOT_DIR'], 'fidelity') }

    def write_csv(dir, basename, rows)
      FileUtils.mkdir_p(dir)
      header = "Account Number,Account Name,Symbol,Description,Quantity,Last Price,Last Price Change,Current Value,Today's Gain/Loss Dollar,Today's Gain/Loss Percent,Total Gain/Loss Dollar,Total Gain/Loss Percent,Percent Of Account,Cost Basis Total,Average Cost Basis,Type"
      lines = [header]
      rows.each do |r|
        lines << "X,Indv,#{r[:symbol]},Desc,#{r[:shares]},$#{r[:last_price]},$0,$#{r[:current_value] || (r[:shares].to_f * r[:last_price].to_f).round(2)},$0,0%,$0,0%,1%,$#{r[:cost_value] || 0},$#{r[:cost_basis] || r[:last_price]},Cash"
      end
      File.write(File.join(dir, basename), lines.join("\n"))
    end

    describe '.pending_backfill_paths' do
      it 'lists CSVs in the input dir without snapshots' do
        write_csv(input_dir, 'Portfolio_Positions_Apr-28-2026.csv', [{ symbol: 'A', shares: 10, last_price: 100 }])
        write_csv(input_dir, 'Portfolio_Positions_Apr-29-2026.csv', [{ symbol: 'A', shares: 10, last_price: 105 }])
        expect(FidelityImporter.pending_backfill_count).to eq(2)
      end

      it 'also picks up CSVs sitting in the snapshot output dir (user mistake)' do
        write_csv(output_dir, 'Portfolio_Positions_Apr-28-2026.csv', [{ symbol: 'A', shares: 10, last_price: 100 }])
        expect(FidelityImporter.pending_backfill_count).to eq(1)
      end

      it 'skips CSVs that already have a JSON snapshot' do
        write_csv(input_dir, 'Portfolio_Positions_Apr-28-2026.csv', [{ symbol: 'A', shares: 10, last_price: 100 }])
        ImportSnapshotStore.write(source: 'fidelity', basename: 'Portfolio_Positions_Apr-28-2026',
                                  data: { 'file_date' => '2026-04-28', 'positions' => [] })
        expect(FidelityImporter.pending_backfill_count).to eq(0)
      end

      it 'sorts oldest-first by filename date' do
        write_csv(input_dir, 'Portfolio_Positions_Apr-30-2026.csv', [{ symbol: 'A', shares: 10, last_price: 100 }])
        write_csv(input_dir, 'Portfolio_Positions_Apr-28-2026.csv', [{ symbol: 'A', shares: 10, last_price: 100 }])
        paths = FidelityImporter.pending_backfill_paths
        expect(paths.map { |p| File.basename(p) }).to eq([
          'Portfolio_Positions_Apr-28-2026.csv',
          'Portfolio_Positions_Apr-30-2026.csv'
        ])
      end
    end

    describe '.backfill_snapshots!' do
      it 'snapshots every pending CSV without mutating the portfolio store' do
        write_csv(input_dir, 'Portfolio_Positions_Apr-28-2026.csv', [{ symbol: 'A', shares: 10, last_price: 100 }])
        write_csv(input_dir, 'Portfolio_Positions_Apr-29-2026.csv', [{ symbol: 'A', shares: 10, last_price: 105 }])
        result = FidelityImporter.backfill_snapshots!
        expect(result[:snapshotted].length).to eq(2)
        expect(result[:errors]).to be_empty
        expect(ImportSnapshotStore.list(source: 'fidelity').length).to eq(2)
        expect(PortfolioStore.positions).to be_empty # not touched
      end

      it 'is idempotent — second run snapshots nothing' do
        write_csv(input_dir, 'Portfolio_Positions_Apr-28-2026.csv', [{ symbol: 'A', shares: 10, last_price: 100 }])
        FidelityImporter.backfill_snapshots!
        second = FidelityImporter.backfill_snapshots!
        expect(second[:snapshotted]).to be_empty
      end
    end
  end

  describe 'GET /portfolio (history rendering)' do
    it 'omits the chart section when there are no snapshots' do
      get '/portfolio'
      expect(last_response.status).to eq(200)
      expect(last_response.body).not_to include('Portfolio value over time')
    end

    it 'renders the chart section when there are 2+ snapshots' do
      write_snapshot('2026-04-28', [{ 'symbol' => 'A', 'shares' => 10, 'cost_basis' => 100, 'last_price' => 100, 'current_value' => 1000, 'cost_value' => 1000 }])
      write_snapshot('2026-04-29', [{ 'symbol' => 'A', 'shares' => 10, 'cost_basis' => 100, 'last_price' => 105, 'current_value' => 1050, 'cost_value' => 1000 }])
      get '/portfolio'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('Portfolio value over time')
      expect(last_response.body).to include('id="portfolio-history-chart"')
      expect(last_response.body).to include('window.PORTFOLIO_HISTORY')
    end

    it 'renders the single-snapshot empty-state when there is exactly one' do
      write_snapshot('2026-04-28', [{ 'symbol' => 'A', 'shares' => 10, 'last_price' => 100, 'current_value' => 1000 }])
      get '/portfolio'
      expect(last_response.body).to include('Only')
      expect(last_response.body).to include('one snapshot')
    end
  end

  describe 'POST /portfolio/import/fidelity/backfill' do
    let(:input_dir) { ENV['FIDELITY_IMPORT_DIR'] }

    it 'snapshots pending CSVs and redirects with the count' do
      FileUtils.mkdir_p(input_dir)
      header = "Account Number,Account Name,Symbol,Description,Quantity,Last Price,Last Price Change,Current Value,Today's Gain/Loss Dollar,Today's Gain/Loss Percent,Total Gain/Loss Dollar,Total Gain/Loss Percent,Percent Of Account,Cost Basis Total,Average Cost Basis,Type"
      File.write(File.join(input_dir, 'Portfolio_Positions_Apr-28-2026.csv'),
                 header + "\nX,Indv,AAPL,Apple,10,$100,$0,$1000,$0,0%,$0,0%,1%,$1000,$100,Cash")
      post '/portfolio/import/fidelity/backfill'
      expect(last_response.status).to eq(302)
      expect(last_response.headers['Location']).to include('backfill_count=1')
      expect(ImportSnapshotStore.list(source: 'fidelity').length).to eq(1)
    end
  end

  describe 'GET /api/portfolio/history' do
    it 'returns time_series + per_symbol JSON' do
      write_snapshot('2026-04-28', [{ 'symbol' => 'A', 'shares' => 10, 'last_price' => 100, 'current_value' => 1000 }])
      write_snapshot('2026-04-29', [{ 'symbol' => 'A', 'shares' => 10, 'last_price' => 110, 'current_value' => 1100 }])
      get '/api/portfolio/history'
      expect(last_response.status).to eq(200)
      json = JSON.parse(last_response.body)
      expect(json).to include('time_series', 'per_symbol', 'generated_at')
      expect(json['time_series'].length).to eq(2)
      expect(json['per_symbol']).to include('A')
    end
  end
end
