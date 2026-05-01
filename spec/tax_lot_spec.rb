require 'rack/test'
require 'rspec'
require 'tmpdir'
require 'fileutils'
require 'json'

ENV['RACK_ENV'] = 'test'

require_relative '../app/main'
require_relative '../app/tax_lot'
require_relative '../app/wash_sale'
require_relative '../app/analytics/benchmark'

RSpec.describe 'Tax lots + wash sale + benchmark' do
  include Rack::Test::Methods

  def app
    TMoneyTerminal
  end

  around(:each) do |ex|
    Dir.mktmpdir do |dir|
      ENV['PORTFOLIO_PATH']        = File.join(dir, 'portfolio.json')
      ENV['TRADES_PATH']           = File.join(dir, 'trades.json')
      ENV['IMPORT_SNAPSHOT_DIR']   = File.join(dir, 'imports')
      ENV['SYMBOLS_EXTENDED_PATH'] = File.join(dir, 'symbols_extended.json')
      ENV['WATCHLIST_PATH']        = File.join(dir, 'watchlist.json')
      ENV['ALERTS_PATH']           = File.join(dir, 'alerts.json')
      SymbolIndex.reset_extensions!
      ex.run
      SymbolIndex.reset_extensions!
      %w[PORTFOLIO_PATH TRADES_PATH IMPORT_SNAPSHOT_DIR SYMBOLS_EXTENDED_PATH WATCHLIST_PATH ALERTS_PATH].each { |k| ENV.delete(k) }
    end
  end

  # ===========================================================================
  # TaxLot.classify
  # ===========================================================================
  describe 'TaxLot.classify' do
    it 'classifies a lot held > 1 year as long-term' do
      lot = { symbol: 'AAPL', shares: 10, acquired_at: '2024-01-01', cost_basis: 150.0 }
      result = TaxLot.classify(lot: lot, sold_at: '2026-04-30')
      expect(result[:holding_period]).to eq('long')
      expect(result[:days_held]).to be > 365
      expect(result[:source]).to eq('lot')
    end

    it 'classifies a lot held ≤ 1 year as short-term' do
      lot = { symbol: 'AAPL', shares: 10, acquired_at: '2026-01-01', cost_basis: 150.0 }
      result = TaxLot.classify(lot: lot, sold_at: '2026-04-30')
      expect(result[:holding_period]).to eq('short')
      expect(result[:days_held]).to be <= 365
    end

    it 'returns unknown when no acquired_at and no snapshot match' do
      lot = { symbol: 'NOSYM', shares: 10, acquired_at: nil, cost_basis: 1.0, created_at: '2026-04-01T00:00:00Z' }
      result = TaxLot.classify(lot: lot, sold_at: '2026-04-30')
      expect(result[:holding_period]).to eq('unknown')
      expect(result[:source]).to eq('unknown')
    end

    it 'falls back to the earliest snapshot containing the symbol when acquired_at is nil' do
      ImportSnapshotStore.write(
        source: 'fidelity',
        basename: 'Portfolio_Positions_Mar-15-2024',
        data: { 'file_date' => '2024-03-15', 'positions' => [{ 'symbol' => 'XYZ', 'shares' => 10 }] }
      )
      ImportSnapshotStore.write(
        source: 'fidelity',
        basename: 'Portfolio_Positions_Apr-30-2026',
        data: { 'file_date' => '2026-04-30', 'positions' => [{ 'symbol' => 'XYZ', 'shares' => 10 }] }
      )
      lot = { symbol: 'XYZ', shares: 10, acquired_at: nil, cost_basis: 100.0 }
      result = TaxLot.classify(lot: lot, sold_at: '2026-04-30')
      expect(result[:source]).to eq('snapshot')
      expect(result[:acquired_at_effective]).to eq('2024-03-15')
      expect(result[:holding_period]).to eq('long') # > 365 days from 2024-03-15
    end

    it 'aggregate_realized splits short-term + long-term P&L' do
      lots_closed = [
        { realized_pl: 1000.0, holding_period: 'short' },
        { realized_pl:  500.0, holding_period: 'long'  },
        { realized_pl: -200.0, holding_period: 'short' },
        { realized_pl:  100.0, holding_period: 'unknown' }
      ]
      result = TaxLot.aggregate_realized(lots_closed)
      expect(result[:short_term_pl]).to eq(800.0)
      expect(result[:long_term_pl]).to eq(500.0)
      expect(result[:unknown_pl]).to eq(100.0)
    end
  end

  # ===========================================================================
  # PortfolioStore.close_shares_fifo enrichment
  # ===========================================================================
  describe 'PortfolioStore.close_shares_fifo with tax classification' do
    it 'attaches holding_period to every closed lot' do
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 10, cost_basis: 150.0, acquired_at: '2024-01-01')
      breakdown = PortfolioStore.close_shares_fifo(symbol: 'AAPL', shares: 10, price: 200.0, sold_at: '2026-04-30')
      expect(breakdown[:lots_closed].first[:holding_period]).to eq('long')
      expect(breakdown[:lots_closed].first[:days_held]).to be > 365
    end

    it 'splits short-term + long-term P&L on a multi-lot close' do
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 5, cost_basis: 100.0, acquired_at: '2024-01-01')  # long
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 5, cost_basis: 150.0, acquired_at: '2026-01-01')  # short
      breakdown = PortfolioStore.close_shares_fifo(symbol: 'AAPL', shares: 10, price: 200.0, sold_at: '2026-04-30')
      # Long lot: 5 × ($200 − $100) = $500
      # Short lot: 5 × ($200 − $150) = $250
      expect(breakdown[:long_term_pl]).to eq(500.0)
      expect(breakdown[:short_term_pl]).to eq(250.0)
      expect(breakdown[:realized_pl]).to eq(750.0)
    end
  end

  # ===========================================================================
  # WashSale.check
  # ===========================================================================
  describe 'WashSale.check' do
    it 'returns [] when the sell is at a gain (no wash-sale risk)' do
      breakdown = { symbol: 'AAPL', shares_closed: 10, price: 200.0, sold_at: '2026-04-30', realized_pl: 500.0 }
      expect(WashSale.check(breakdown)).to be_empty
    end

    it 'flags a buy within 30 days BEFORE a loss-sell' do
      TradesStore.record_buy(symbol: 'AAPL', shares: 10, price: 200.0, date: '2026-04-15')
      breakdown = { symbol: 'AAPL', shares_closed: 10, price: 150.0, sold_at: '2026-04-30', realized_pl: -500.0 }
      flags = WashSale.check(breakdown)
      expect(flags.length).to eq(1)
      expect(flags.first[:direction]).to eq('before')
      expect(flags.first[:days_apart]).to eq(15)
    end

    it 'flags a buy within 30 days AFTER a loss-sell' do
      TradesStore.record_buy(symbol: 'AAPL', shares: 10, price: 200.0, date: '2026-05-10')
      breakdown = { symbol: 'AAPL', shares_closed: 10, price: 150.0, sold_at: '2026-04-30', realized_pl: -500.0 }
      flags = WashSale.check(breakdown)
      expect(flags.length).to eq(1)
      expect(flags.first[:direction]).to eq('after')
      expect(flags.first[:days_apart]).to eq(10)
    end

    it 'does NOT flag buys outside the ±30 day window' do
      TradesStore.record_buy(symbol: 'AAPL', shares: 10, price: 200.0, date: '2026-03-01')
      breakdown = { symbol: 'AAPL', shares_closed: 10, price: 150.0, sold_at: '2026-04-30', realized_pl: -500.0 }
      expect(WashSale.check(breakdown)).to be_empty
    end

    it 'does not match across symbols' do
      TradesStore.record_buy(symbol: 'NVDA', shares: 10, price: 200.0, date: '2026-04-15')
      breakdown = { symbol: 'AAPL', shares_closed: 10, price: 150.0, sold_at: '2026-04-30', realized_pl: -500.0 }
      expect(WashSale.check(breakdown)).to be_empty
    end

    it 'summarize_flag produces a useful one-liner with the resume date' do
      flag = {
        matching_buy: { symbol: 'AAPL', shares: 10, date: '2026-04-15' },
        days_apart: 15,
        direction: 'before',
        shares_at_risk: 10,
        allowed_resume_date: '2026-05-31'
      }
      msg = WashSale.summarize_flag(flag)
      expect(msg).to include('AAPL')
      expect(msg).to include('15 days before')
      expect(msg).to include('2026-05-31')
    end
  end

  # ===========================================================================
  # Analytics::Benchmark.compare
  # ===========================================================================
  describe 'Analytics::Benchmark.compare' do
    let(:positions) {
      [
        { symbol: 'AAPL', current_price: 200.0,
          lots: [{ shares: 10, cost_basis: 100.0, acquired_at: '2024-01-02', created_at: '2024-01-02T00:00:00Z' }] }
      ]
    }
    let(:bench_bars) {
      [
        { date: '2024-01-02', close: 100.0 },
        { date: '2026-04-30', close: 130.0 }
      ]
    }
    let(:bars_for) { ->(_sym) { bench_bars } }

    it 'computes portfolio return, benchmark return, and alpha' do
      result = Analytics::Benchmark.compare(positions, bars_for: bars_for)
      # Portfolio: 10 × ($200 − $100) on $1,000 cost = +100% return
      expect(result[:portfolio_return]).to be_within(1e-6).of(1.0)
      # Benchmark: $100 → $130 = +30%
      expect(result[:benchmark_return]).to be_within(1e-6).of(0.3)
      # Alpha = 100% − 30% = 70%
      expect(result[:alpha]).to be_within(1e-6).of(0.7)
      expect(result[:lots_priced]).to eq(1)
      expect(result[:lots_skipped]).to eq(0)
    end

    it 'falls forward to the next available bar when acquired_at lands on a weekend' do
      bars = [
        { date: '2024-01-02', close: 100.0 }, # Tue (weekend skipped)
        { date: '2026-04-30', close: 130.0 }
      ]
      pos_with_weekend_acq = [
        { symbol: 'X', current_price: 200.0,
          lots: [{ shares: 1, cost_basis: 50.0, acquired_at: '2023-12-30' }] } # Sat
      ]
      result = Analytics::Benchmark.compare(pos_with_weekend_acq, bars_for: ->(_) { bars })
      expect(result[:portfolio_return]).to eq(3.0) # ($200 − $50) / $50
      expect(result[:benchmark_return]).to be_within(1e-6).of(0.3)
    end

    it 'returns an empty result when bench bars are empty' do
      result = Analytics::Benchmark.compare(positions, bars_for: ->(_) { [] })
      expect(result[:portfolio_return]).to be_nil
      expect(result[:benchmark_return]).to be_nil
      expect(result[:alpha]).to be_nil
    end

    it 'skips lots with zero cost basis or no current price' do
      bad = [
        { symbol: 'X', current_price: nil, lots: [{ shares: 1, cost_basis: 50.0, acquired_at: '2024-01-02' }] },
        { symbol: 'Y', current_price: 100.0, lots: [{ shares: 1, cost_basis: 0.0,  acquired_at: '2024-01-02' }] }
      ]
      result = Analytics::Benchmark.compare(bad, bars_for: bars_for)
      expect(result[:lots_priced]).to eq(0)
    end
  end

  # ===========================================================================
  # /api/portfolio/sell + /api/portfolio/sell/preview routes
  # ===========================================================================
  describe 'POST /api/portfolio/sell with wash-sale check' do
    it 'returns wash_sale_flags in the response when applicable' do
      # Buy at 100, then sell at 90 with a recent buy → wash sale
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 10, cost_basis: 100.0, acquired_at: '2026-04-15')
      TradesStore.record_buy(symbol: 'AAPL', shares: 10, price: 100.0, date: '2026-04-15')

      header 'Content-Type', 'application/json'
      post '/api/portfolio/sell', { symbol: 'AAPL', shares: 10, price: 90.0, sold_at: '2026-04-30' }.to_json
      expect(last_response).to be_ok
      body = JSON.parse(last_response.body)
      expect(body['realized_pl']).to eq(-100.0)
      expect(body['wash_sale_flags']).not_to be_empty
    end

    it 'persists wash_sale_flags on the trade record' do
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 10, cost_basis: 100.0, acquired_at: '2026-04-15')
      TradesStore.record_buy(symbol: 'AAPL', shares: 10, price: 100.0, date: '2026-04-15')

      header 'Content-Type', 'application/json'
      post '/api/portfolio/sell', { symbol: 'AAPL', shares: 10, price: 90.0, sold_at: '2026-04-30' }.to_json
      sell_record = TradesStore.read.find { |t| t[:side] == 'sell' }
      expect(sell_record[:wash_sale_flags]).not_to be_nil
      expect(sell_record[:short_term_pl]).to eq(-100.0)
    end
  end

  describe 'POST /api/portfolio/sell/preview' do
    it 'returns a non-destructive preview with the breakdown + flags' do
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 10, cost_basis: 100.0, acquired_at: '2026-04-15')
      TradesStore.record_buy(symbol: 'AAPL', shares: 10, price: 100.0, date: '2026-04-15')

      open_before = PortfolioStore.find('AAPL')
      header 'Content-Type', 'application/json'
      post '/api/portfolio/sell/preview', { symbol: 'AAPL', shares: 5, price: 90.0, sold_at: '2026-04-30' }.to_json
      expect(last_response).to be_ok
      body = JSON.parse(last_response.body)
      expect(body['preview']).to be true
      expect(body['realized_pl']).to eq(-50.0)
      expect(body['wash_sale_flags']).not_to be_empty

      # State unchanged
      open_after = PortfolioStore.find('AAPL')
      expect(open_after[:shares]).to eq(open_before[:shares])
    end
  end

  # ===========================================================================
  # /trades + /portfolio renders
  # ===========================================================================
  describe 'GET /trades' do
    it 'renders short-term + long-term YTD cards' do
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 10, cost_basis: 100.0, acquired_at: "#{Date.today.year - 2}-01-01")
      breakdown = PortfolioStore.close_shares_fifo(symbol: 'AAPL', shares: 10, price: 200.0, sold_at: Date.today.iso8601)
      TradesStore.record_sell(breakdown)

      get '/trades'
      expect(last_response).to be_ok
      expect(last_response.body).to include('Short-term (YTD)')
      expect(last_response.body).to include('Long-term (YTD)')
      expect(last_response.body).to include('long') # holding-period badge
    end
  end

  describe 'GET /portfolio benchmark section' do
    it 'renders the Benchmark Comparison cards when historicals are available' do
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 10, cost_basis: 100.0, acquired_at: '2024-01-02')
      MarketDataService.prime_quote!('AAPL', price: 200.0, change_pct: 0)

      bars = [
        { date: '2024-01-02', close: 100.0 },
        { date: Date.today.iso8601, close: 130.0 }
      ]
      allow(MarketDataService).to receive(:historical_cached).with('SPY', '5y').and_return(bars)

      get '/portfolio'
      expect(last_response).to be_ok
      expect(last_response.body).to include('Benchmark Comparison')
      expect(last_response.body).to include('Alpha')
    end
  end

  # ===========================================================================
  # Always-visible tax + wash-sale section on /portfolio
  # ===========================================================================
  describe 'GET /portfolio tax + wash-sale visibility' do
    it 'always renders the tax section even with no realized P&L (so users can find the feature)' do
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 10, cost_basis: 100.0, acquired_at: '2024-01-02')
      MarketDataService.prime_quote!('AAPL', price: 100.0, change_pct: 0)
      get '/portfolio'
      expect(last_response).to be_ok
      expect(last_response.body).to include('Tax + wash-sale')
      expect(last_response.body).to include('Wash-sale warnings')
      expect(last_response.body).to include('No realized gains or losses yet this year')
    end
  end

  # ===========================================================================
  # Per-lot tax preview in the lot-detail expansion
  # ===========================================================================
  describe 'Per-lot "Tax (if sold today)" preview' do
    it 'shows holding-period badge + days-held in the lot detail' do
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 10, cost_basis: 100.0, acquired_at: '2024-01-02')
      MarketDataService.prime_quote!('AAPL', price: 200.0, change_pct: 0)
      get '/portfolio'
      expect(last_response).to be_ok
      expect(last_response.body).to include('Tax (if sold today)')
      expect(last_response.body).to match(/holding-long/) # held > 1y
      expect(last_response.body).to match(/held \d+d/)
    end

    it 'shows "long-term in N days" countdown for short-term lots' do
      # acquired ~6 months ago → still short-term, ~half a year to long-term
      acq = (Date.today - 180).iso8601
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 10, cost_basis: 100.0, acquired_at: acq)
      MarketDataService.prime_quote!('AAPL', price: 200.0, change_pct: 0)
      get '/portfolio'
      expect(last_response.body).to match(/long-term in \d+d/)
      expect(last_response.body).to match(/holding-short/)
    end
  end

  # ===========================================================================
  # Collapsible positions table (default closed)
  # ===========================================================================
  describe 'GET /portfolio positions table is collapsible' do
    it 'wraps the table in <details> with no `open` attribute (default closed)' do
      PortfolioStore.add_lot(symbol: 'AAPL', shares: 10, cost_basis: 100.0, acquired_at: '2024-01-02')
      MarketDataService.prime_quote!('AAPL', price: 200.0, change_pct: 0)
      get '/portfolio'
      expect(last_response.body).to include('<details class="positions-collapsible">')
      # Sanity check: no `open` attribute on the wrapper.
      expect(last_response.body).not_to match(/<details class="positions-collapsible"\s+open/)
      expect(last_response.body).to include('All positions')
    end

    it 'summary header shows the count' do
      3.times do |i|
        PortfolioStore.add_lot(symbol: %w[AAPL NVDA VOO][i], shares: 1, cost_basis: 100.0)
      end
      get '/portfolio'
      # Three positions → "(3)"
      expect(last_response.body).to match(/<strong>All positions<\/strong>\s*\n?\s*\(3\)/)
    end
  end
end
