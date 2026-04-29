require 'rack/test'
require 'rspec'
require 'tmpdir'
require 'fileutils'
require 'json'

ENV['RACK_ENV'] = 'test'

require_relative '../app/main'
require_relative '../app/portfolio_diff'
require_relative '../app/import_snapshot_store'
require_relative '../app/fidelity_importer'

RSpec.describe 'PortfolioDiff + /portfolio/drift' do
  include Rack::Test::Methods

  def app
    TMoneyTerminal
  end

  around(:each) do |ex|
    Dir.mktmpdir do |dir|
      ENV['IMPORT_SNAPSHOT_DIR'] = File.join(dir, 'imports')
      ENV['PORTFOLIO_PATH']      = File.join(dir, 'portfolio.json')
      ENV['TRADES_PATH']         = File.join(dir, 'trades.json')
      ex.run
      %w[IMPORT_SNAPSHOT_DIR PORTFOLIO_PATH TRADES_PATH].each { |k| ENV.delete(k) }
    end
  end

  # Helper: write a snapshot with hand-shaped positions.
  def snap(basename, file_date, positions)
    ImportSnapshotStore.write(
      source: 'fidelity',
      basename: basename,
      data: { 'file_date' => file_date, 'positions' => positions }
    )
  end

  # --- compute() ------------------------------------------------------------

  describe 'PortfolioDiff.compute' do
    let(:before_snap) {
      { 'file_date' => '2026-04-22', 'basename' => 'before',
        'positions' => [
          { 'symbol' => 'AAPL', 'shares' => 10, 'cost_basis' => 150.0, 'current_value' => 2000.0, 'pct_account' => 10.0 },
          { 'symbol' => 'NVDA', 'shares' => 5,  'cost_basis' => 100.0, 'current_value' => 2000.0, 'pct_account' => 10.0 },
          { 'symbol' => 'TSLA', 'shares' => 8,  'cost_basis' => 200.0, 'current_value' => 1600.0, 'pct_account' => 8.0  }
        ] }
    }
    let(:after_snap) {
      { 'file_date' => '2026-04-29', 'basename' => 'after',
        'positions' => [
          # AAPL: same shares, value changed
          { 'symbol' => 'AAPL', 'shares' => 10, 'cost_basis' => 150.0, 'current_value' => 2200.0, 'pct_account' => 11.0 },
          # NVDA: bought 5 more
          { 'symbol' => 'NVDA', 'shares' => 10, 'cost_basis' => 110.0, 'current_value' => 4000.0, 'pct_account' => 20.0 },
          # TSLA: removed entirely
          # MSFT: brand new
          { 'symbol' => 'MSFT', 'shares' => 3,  'cost_basis' => 400.0, 'current_value' => 1200.0, 'pct_account' => 6.0 }
        ] }
    }
    let(:diff) { PortfolioDiff.compute(before: before_snap, after: after_snap) }

    it 'classifies status correctly: added / removed / changed / unchanged' do
      by_sym = diff[:rows].each_with_object({}) { |r, h| h[r[:symbol]] = r }
      expect(by_sym['MSFT'][:status]).to eq('added')
      expect(by_sym['TSLA'][:status]).to eq('removed')
      expect(by_sym['NVDA'][:status]).to eq('changed')
      expect(by_sym['AAPL'][:status]).to eq('unchanged') # shares same; value-only deltas don't reclassify
    end

    it 'computes shares_delta with correct sign + zero on unchanged' do
      by_sym = diff[:rows].each_with_object({}) { |r, h| h[r[:symbol]] = r }
      expect(by_sym['NVDA'][:shares_delta]).to eq(5.0)
      expect(by_sym['TSLA'][:shares_delta]).to eq(-8.0)
      expect(by_sym['MSFT'][:shares_delta]).to eq(3.0)
      expect(by_sym['AAPL'][:shares_delta]).to eq(0.0)
    end

    it 'computes value_delta and cost_basis_delta' do
      by_sym = diff[:rows].each_with_object({}) { |r, h| h[r[:symbol]] = r }
      expect(by_sym['AAPL'][:value_delta]).to eq(200.00)        # 2200 - 2000
      expect(by_sym['NVDA'][:value_delta]).to eq(2000.00)        # 4000 - 2000
      expect(by_sym['NVDA'][:cost_basis_delta]).to eq(10.00)    # 110 - 100
      expect(by_sym['TSLA'][:value_delta]).to eq(-1600.00)
    end

    it 'sorts rows by absolute value_delta descending' do
      symbols = diff[:rows].map { |r| r[:symbol] }
      # NVDA (+2000), TSLA (-1600), MSFT (+1200), AAPL (+200)
      expect(symbols).to eq(%w[NVDA TSLA MSFT AAPL])
    end

    it 'aggregates totals: value delta + counts per status' do
      t = diff[:totals]
      expect(t[:before_value]).to eq(5600.00)
      expect(t[:after_value]).to  eq(7400.00)
      expect(t[:value_delta]).to  eq(1800.00)
      expect(t[:added_count]).to eq(1)
      expect(t[:removed_count]).to eq(1)
      expect(t[:changed_count]).to eq(1)
      expect(t[:unchanged_count]).to eq(1)
    end

    it 'embeds before / after metadata on the diff' do
      expect(diff[:before_meta][:basename]).to eq('before')
      expect(diff[:after_meta][:file_date]).to eq('2026-04-29')
    end

    it 'raises on non-Hash inputs' do
      expect { PortfolioDiff.compute(before: nil,         after: after_snap) }.to raise_error(ArgumentError)
      expect { PortfolioDiff.compute(before: before_snap, after: 'oops')     }.to raise_error(ArgumentError)
    end
  end

  # --- compute_latest_pair() ------------------------------------------------

  describe 'PortfolioDiff.compute_latest_pair' do
    it 'returns nil when fewer than 2 snapshots exist' do
      expect(PortfolioDiff.compute_latest_pair(source: 'fidelity')).to be_nil
      snap('Portfolio_Positions_Apr-29-2026', '2026-04-29',
           [{ 'symbol' => 'AAPL', 'shares' => 10, 'current_value' => 2000.0, 'cost_basis' => 150.0 }])
      expect(PortfolioDiff.compute_latest_pair(source: 'fidelity')).to be_nil
    end

    it 'picks the two newest by filename date and returns a diff' do
      snap('Portfolio_Positions_Mar-15-2026', '2026-03-15',
           [{ 'symbol' => 'AAPL', 'shares' => 5, 'current_value' => 1000.0, 'cost_basis' => 200.0 }])
      snap('Portfolio_Positions_Apr-29-2026', '2026-04-29',
           [{ 'symbol' => 'AAPL', 'shares' => 10, 'current_value' => 2000.0, 'cost_basis' => 150.0 }])
      diff = PortfolioDiff.compute_latest_pair(source: 'fidelity')
      expect(diff).not_to be_nil
      expect(diff[:before_meta][:file_date]).to eq('2026-03-15')
      expect(diff[:after_meta][:file_date]).to  eq('2026-04-29')
      expect(diff[:rows].first[:shares_delta]).to eq(5.0)
    end
  end

  # --- HTTP routes ----------------------------------------------------------

  describe 'GET /portfolio/drift' do
    it 'shows the empty state when no snapshots exist' do
      get '/portfolio/drift'
      expect(last_response).to be_ok
      expect(last_response.body).to include('No broker imports yet')
    end

    it 'shows the single-snapshot state when only one exists' do
      snap('Portfolio_Positions_Apr-29-2026', '2026-04-29',
           [{ 'symbol' => 'AAPL', 'shares' => 10, 'current_value' => 2000.0, 'cost_basis' => 150.0 }])
      get '/portfolio/drift'
      expect(last_response.body).to include('Only one snapshot exists')
    end

    it 'renders the drift table with both dates when 2+ snapshots exist' do
      snap('Portfolio_Positions_Mar-15-2026', '2026-03-15',
           [{ 'symbol' => 'AAPL', 'shares' => 5, 'current_value' => 1000.0, 'cost_basis' => 200.0 }])
      snap('Portfolio_Positions_Apr-29-2026', '2026-04-29',
           [{ 'symbol' => 'AAPL', 'shares' => 10, 'current_value' => 2000.0, 'cost_basis' => 150.0 }])
      get '/portfolio/drift'
      expect(last_response).to be_ok
      expect(last_response.body).to include('2026-03-15')
      expect(last_response.body).to include('2026-04-29')
      expect(last_response.body).to include('AAPL')
    end
  end

  describe 'GET /api/portfolio/drift' do
    it '404s when fewer than 2 snapshots exist' do
      get '/api/portfolio/drift'
      expect(last_response.status).to eq(404)
    end

    it 'returns the diff JSON when 2+ snapshots exist' do
      snap('Portfolio_Positions_Mar-15-2026', '2026-03-15',
           [{ 'symbol' => 'AAPL', 'shares' => 5, 'current_value' => 1000.0, 'cost_basis' => 200.0 }])
      snap('Portfolio_Positions_Apr-29-2026', '2026-04-29',
           [{ 'symbol' => 'AAPL', 'shares' => 10, 'current_value' => 2000.0, 'cost_basis' => 150.0 }])
      get '/api/portfolio/drift'
      expect(last_response).to be_ok
      body = JSON.parse(last_response.body)
      expect(body['totals']['value_delta']).to eq(1000.0)
      expect(body['rows'].first['symbol']).to eq('AAPL')
    end
  end

  # --- Market-aware cache TTL ------------------------------------------------

  describe 'MarketDataService.market_open? + effective_ttl' do
    it 'honors the MARKET_OPEN env override (true case)' do
      ENV['MARKET_OPEN'] = '1'
      expect(MarketDataService.market_open?).to be true
      expect(MarketDataService.effective_ttl).to eq(MarketDataService::CACHE_TTL)
    ensure
      ENV.delete('MARKET_OPEN')
    end

    it 'honors the MARKET_OPEN env override (false case) and bumps TTL' do
      ENV['MARKET_OPEN'] = 'false'
      expect(MarketDataService.market_open?).to be false
      expect(MarketDataService.effective_ttl).to eq(MarketDataService::CACHE_TTL_CLOSED)
      expect(MarketDataService::CACHE_TTL_CLOSED).to be > MarketDataService::CACHE_TTL
    ensure
      ENV.delete('MARKET_OPEN')
    end
  end

  # --- Snapshot fallback in fetch_quote -------------------------------------

  describe 'MarketDataService.build_quote_from_snapshot' do
    it 'returns nil when no snapshot exists for the symbol' do
      expect(MarketDataService.send(:build_quote_from_snapshot, 'NOSYM')).to be_nil
    end

    it 'returns an AV-shaped quote when the latest snapshot has the symbol' do
      snap('Portfolio_Positions_Apr-29-2026', '2026-04-29', [
        { 'symbol' => 'AAPL', 'shares' => 10, 'last_price' => 270.17,
          'day_change_pct' => -0.20, 'current_value' => 2701.7, 'cost_basis' => 150.0 }
      ])
      q = MarketDataService.send(:build_quote_from_snapshot, 'AAPL')
      expect(q).not_to be_nil
      expect(q['05. price']).to eq('270.17')
      expect(q['10. change percent']).to eq('-0.2%')
    end

    it 'returns nil when the snapshot row has no usable price' do
      snap('Portfolio_Positions_Apr-29-2026', '2026-04-29', [
        { 'symbol' => 'OBSCURE', 'shares' => 1, 'last_price' => 0, 'cost_basis' => 1.0, 'current_value' => 1 }
      ])
      expect(MarketDataService.send(:build_quote_from_snapshot, 'OBSCURE')).to be_nil
    end
  end
end
