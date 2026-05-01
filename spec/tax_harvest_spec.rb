require 'rack/test'
require 'rspec'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'date'

ENV['RACK_ENV'] = 'test'

require_relative '../app/main'
require_relative '../app/profile_store'
require_relative '../app/tax_harvester'
require_relative '../app/portfolio_store'
require_relative '../app/trades_store'

RSpec.describe 'ProfileStore + TaxHarvester + tax-harvest routes' do
  include Rack::Test::Methods

  def app
    TMoneyTerminal
  end

  around(:each) do |ex|
    Dir.mktmpdir do |dir|
      ENV['PROFILE_PATH']          = File.join(dir, 'profile.json')
      ENV['PORTFOLIO_PATH']        = File.join(dir, 'portfolio.json')
      ENV['TRADES_PATH']           = File.join(dir, 'trades.json')
      ENV['IMPORT_SNAPSHOT_DIR']   = File.join(dir, 'imports')
      ENV['SYMBOLS_EXTENDED_PATH'] = File.join(dir, 'symbols_extended.json')
      ENV['WATCHLIST_PATH']        = File.join(dir, 'watchlist.json')
      ENV['ALERTS_PATH']           = File.join(dir, 'alerts.json')
      SymbolIndex.reset_extensions! if defined?(SymbolIndex) && SymbolIndex.respond_to?(:reset_extensions!)
      ex.run
      SymbolIndex.reset_extensions! if defined?(SymbolIndex) && SymbolIndex.respond_to?(:reset_extensions!)
      %w[PROFILE_PATH PORTFOLIO_PATH TRADES_PATH IMPORT_SNAPSHOT_DIR
         SYMBOLS_EXTENDED_PATH WATCHLIST_PATH ALERTS_PATH].each { |k| ENV.delete(k) }
    end
  end

  # Build a position row in the same shape valuate_position emits — that's
  # what /portfolio/tax-harvest hands to TaxHarvester. We bypass valuate_position
  # in the unit tests so providers never get touched.
  def position(symbol:, lots:, current_price:)
    {
      symbol:        symbol,
      shares:        lots.sum { |l| l[:shares].to_f },
      cost_basis:    lots.sum { |l| l[:shares].to_f * l[:cost_basis].to_f } / lots.sum { |l| l[:shares].to_f },
      current_price: current_price,
      lots:          lots
    }
  end

  def lot(id:, shares:, cost_basis:, acquired_at:)
    {
      id:          id,
      symbol:      nil, # filled by caller
      shares:      shares,
      cost_basis:  cost_basis,
      acquired_at: acquired_at,
      created_at:  Time.now.utc.iso8601
    }
  end

  # ===========================================================================
  # ProfileStore
  # ===========================================================================
  describe ProfileStore do
    it 'returns DEFAULTS merged with empty persisted state' do
      p = ProfileStore.read
      expect(p[:current_age]).to be_nil
      expect(p[:retirement_age]).to eq(65)
      expect(p[:risk_tolerance]).to eq('moderate')
      expect(p[:federal_ltcg_rate]).to eq(0.15)
      expect(p[:federal_ordinary_rate]).to eq(0.22)
      expect(p[:niit_applies]).to eq(false)
    end

    it 'reports configured? false until current_age is set' do
      expect(ProfileStore.configured?).to eq(false)
      ProfileStore.update(current_age: 56)
      expect(ProfileStore.configured?).to eq(true)
    end

    it 'computes years_to_retirement = retirement_age - current_age' do
      ProfileStore.update(current_age: 56, retirement_age: 63)
      expect(ProfileStore.years_to_retirement).to eq(7)
    end

    it 'returns nil years_to_retirement when current_age is unset' do
      expect(ProfileStore.years_to_retirement).to be_nil
    end

    it 'persists across reads' do
      ProfileStore.update(current_age: 40, risk_tolerance: 'aggressive', federal_ltcg_rate: 0.20)
      again = ProfileStore.read
      expect(again[:current_age]).to eq(40)
      expect(again[:risk_tolerance]).to eq('aggressive')
      expect(again[:federal_ltcg_rate]).to eq(0.20)
    end

    it 'rejects out-of-range age' do
      expect { ProfileStore.update(current_age: -1) }.to raise_error(ArgumentError)
      expect { ProfileStore.update(current_age: 200) }.to raise_error(ArgumentError)
    end

    it 'rejects unknown risk_tolerance' do
      expect { ProfileStore.update(risk_tolerance: 'reckless') }.to raise_error(ArgumentError)
    end

    it 'rejects rates outside 0..0.5' do
      expect { ProfileStore.update(federal_ordinary_rate: 0.9) }.to raise_error(ArgumentError)
      expect { ProfileStore.update(federal_ltcg_rate: -0.1) }.to raise_error(ArgumentError)
    end

    it 'rejects retirement_age earlier than current_age' do
      expect { ProfileStore.update(current_age: 60, retirement_age: 50) }.to raise_error(ArgumentError)
    end

    it 'leaves existing fields untouched when a value is empty' do
      ProfileStore.update(current_age: 56, retirement_age: 63)
      ProfileStore.update(current_age: '', retirement_age: '')
      p = ProfileStore.read
      expect(p[:current_age]).to eq(56)
      expect(p[:retirement_age]).to eq(63)
    end

    it 'coerces niit_applies from string truthy values' do
      ProfileStore.update(niit_applies: 'true')
      expect(ProfileStore.read[:niit_applies]).to eq(true)
      ProfileStore.update(niit_applies: 'false')
      expect(ProfileStore.read[:niit_applies]).to eq(false)
    end
  end

  # ===========================================================================
  # TaxHarvester
  # ===========================================================================
  describe TaxHarvester do
    let(:profile) do
      {
        current_age: 56, retirement_age: 63,
        risk_tolerance: 'moderate',
        federal_ltcg_rate: 0.15, federal_ordinary_rate: 0.22,
        state_tax_rate: nil, niit_applies: false
      }
    end

    let(:today) { Date.today }
    let(:two_years_ago) { (today - 800).iso8601 }
    let(:six_months_ago) { (today - 180).iso8601 }
    let(:eleven_months_ago) { (today - 340).iso8601 }

    describe '.candidates' do
      it 'returns nothing when no positions are underwater' do
        positions = [position(
          symbol: 'AAPL',
          lots: [lot(id: 'a', shares: 10, cost_basis: 100, acquired_at: two_years_ago)],
          current_price: 150.0
        )]
        cands = TaxHarvester.candidates(positions: positions, profile: profile, trades: [])
        expect(cands).to be_empty
      end

      it 'flags an underwater long-term lot and computes savings at LTCG rate' do
        positions = [position(
          symbol: 'XYZ',
          lots: [lot(id: 'lt', shares: 10, cost_basis: 100, acquired_at: two_years_ago)],
          current_price: 70.0
        )]
        cands = TaxHarvester.candidates(positions: positions, profile: profile, trades: [])
        expect(cands.length).to eq(1)
        c = cands.first
        expect(c[:holding_period]).to eq('long')
        expect(c[:unrealized_pl]).to eq(-300.0)
        # 300 * 0.15 (LTCG)
        expect(c[:estimated_tax_savings]).to eq(45.0)
        expect(c[:recommendation][:action]).to eq('harvest')
      end

      it 'flags an underwater short-term lot and computes savings at ordinary rate' do
        positions = [position(
          symbol: 'XYZ',
          lots: [lot(id: 'st', shares: 10, cost_basis: 100, acquired_at: six_months_ago)],
          current_price: 70.0
        )]
        cands = TaxHarvester.candidates(positions: positions, profile: profile, trades: [])
        c = cands.first
        expect(c[:holding_period]).to eq('short')
        # 300 * 0.22 (ordinary)
        expect(c[:estimated_tax_savings]).to eq(66.0)
      end

      it 'includes state tax + NIIT when configured' do
        prof = profile.merge(state_tax_rate: 0.05, niit_applies: true)
        positions = [position(
          symbol: 'XYZ',
          lots: [lot(id: 'lt', shares: 10, cost_basis: 100, acquired_at: two_years_ago)],
          current_price: 70.0
        )]
        cands = TaxHarvester.candidates(positions: positions, profile: prof, trades: [])
        # 300 * (0.15 + 0.05 + 0.038) = 300 * 0.238 = 71.4
        expect(cands.first[:estimated_tax_savings]).to be_within(0.01).of(71.4)
      end

      it 'sorts candidates by estimated tax savings descending' do
        positions = [
          position(symbol: 'A', lots: [lot(id: 'a', shares: 10, cost_basis: 100, acquired_at: two_years_ago)], current_price: 95.0),  # -50 * 0.15 = 7.5
          position(symbol: 'B', lots: [lot(id: 'b', shares: 10, cost_basis: 100, acquired_at: two_years_ago)], current_price: 50.0),  # -500 * 0.15 = 75
          position(symbol: 'C', lots: [lot(id: 'c', shares: 10, cost_basis: 100, acquired_at: two_years_ago)], current_price: 80.0)   # -200 * 0.15 = 30
        ]
        cands = TaxHarvester.candidates(positions: positions, profile: profile, trades: [])
        expect(cands.map { |c| c[:symbol] }).to eq(%w[B C A])
      end

      it 'recommends "skip" on a moderate profile when loss is below 2% threshold' do
        positions = [position(
          symbol: 'AAPL',
          lots: [lot(id: 'a', shares: 10, cost_basis: 100, acquired_at: two_years_ago)],
          current_price: 99.0  # -1% only
        )]
        cands = TaxHarvester.candidates(positions: positions, profile: profile, trades: [])
        expect(cands.first[:recommendation][:action]).to eq('skip')
        expect(cands.first[:recommendation][:reason]).to match(/too small/)
      end

      it 'recommends "harvest" on aggressive profile for the same 1% loss' do
        positions = [position(
          symbol: 'AAPL',
          lots: [lot(id: 'a', shares: 10, cost_basis: 100, acquired_at: two_years_ago)],
          current_price: 99.0
        )]
        prof = profile.merge(risk_tolerance: 'aggressive')
        cands = TaxHarvester.candidates(positions: positions, profile: prof, trades: [])
        expect(cands.first[:recommendation][:action]).to eq('harvest')
      end

      it 'recommends "skip" on conservative profile when loss is below 5% threshold' do
        positions = [position(
          symbol: 'AAPL',
          lots: [lot(id: 'a', shares: 10, cost_basis: 100, acquired_at: two_years_ago)],
          current_price: 96.0  # -4%
        )]
        prof = profile.merge(risk_tolerance: 'conservative')
        cands = TaxHarvester.candidates(positions: positions, profile: prof, trades: [])
        expect(cands.first[:recommendation][:action]).to eq('skip')
      end

      it 'attaches replacement suggestions for known symbols' do
        positions = [position(
          symbol: 'SPY',
          lots: [lot(id: 'spy', shares: 10, cost_basis: 500, acquired_at: two_years_ago)],
          current_price: 400.0
        )]
        cands = TaxHarvester.candidates(positions: positions, profile: profile, trades: [])
        expect(cands.first[:replacement_suggestions]).to include('VTI')
      end

      it 'returns empty replacement_suggestions for unknown symbols' do
        positions = [position(
          symbol: 'OBSCURE',
          lots: [lot(id: 'o', shares: 10, cost_basis: 100, acquired_at: two_years_ago)],
          current_price: 70.0
        )]
        cands = TaxHarvester.candidates(positions: positions, profile: profile, trades: [])
        expect(cands.first[:replacement_suggestions]).to eq([])
      end

      it 'flags wash-sale risk and advises skip when a same-symbol BUY landed within 30 days' do
        # Record a BUY in TradesStore within the wash window
        TradesStore.record_buy(
          symbol: 'XYZ',
          shares: 5,
          price:  80.0,
          date:   (today - 5).iso8601
        )
        positions = [position(
          symbol: 'XYZ',
          lots: [lot(id: 'lt', shares: 10, cost_basis: 100, acquired_at: two_years_ago)],
          current_price: 70.0
        )]
        cands = TaxHarvester.candidates(positions: positions, profile: profile, trades: TradesStore.read)
        c = cands.first
        expect(c[:wash_sale_flags]).not_to be_empty
        expect(c[:recommendation][:action]).to eq('skip')
        expect(c[:recommendation][:reason]).to match(/wash-sale/)
      end

      it 'recommends "wait" on conservative profile when ST loss is days from going long-term' do
        positions = [position(
          symbol: 'XYZ',
          lots: [lot(id: 'st', shares: 10, cost_basis: 100, acquired_at: (today - 350).iso8601)],
          current_price: 60.0  # -40% loss, well above any threshold
        )]
        prof = profile.merge(risk_tolerance: 'conservative')
        cands = TaxHarvester.candidates(positions: positions, profile: prof, trades: [])
        expect(cands.first[:recommendation][:action]).to eq('wait')
      end

      it 'recommends "harvest" on aggressive profile in the same near-LT scenario' do
        positions = [position(
          symbol: 'XYZ',
          lots: [lot(id: 'st', shares: 10, cost_basis: 100, acquired_at: (today - 350).iso8601)],
          current_price: 60.0
        )]
        prof = profile.merge(risk_tolerance: 'aggressive')
        cands = TaxHarvester.candidates(positions: positions, profile: prof, trades: [])
        expect(cands.first[:recommendation][:action]).to eq('harvest')
      end

      it 'skips lots with non-positive shares or cost basis' do
        positions = [position(
          symbol: 'X',
          lots: [
            lot(id: 'a', shares: 0, cost_basis: 100, acquired_at: two_years_ago),
            lot(id: 'b', shares: 10, cost_basis: 0, acquired_at: two_years_ago)
          ],
          current_price: 50.0
        )]
        cands = TaxHarvester.candidates(positions: positions, profile: profile, trades: [])
        expect(cands).to be_empty
      end

      it 'skips positions with no current price' do
        positions = [position(
          symbol: 'X',
          lots: [lot(id: 'a', shares: 10, cost_basis: 100, acquired_at: two_years_ago)],
          current_price: nil
        )]
        cands = TaxHarvester.candidates(positions: positions, profile: profile, trades: [])
        expect(cands).to be_empty
      end
    end

    describe '.crossing_threshold' do
      it 'flags lots within 30 days of crossing ST → LT' do
        positions = [position(
          symbol: 'X',
          lots: [lot(id: 'a', shares: 10, cost_basis: 100, acquired_at: (today - 350).iso8601)],
          current_price: 110.0
        )]
        out = TaxHarvester.crossing_threshold(positions: positions)
        expect(out.length).to eq(1)
        expect(out.first[:days_to_long_term]).to be <= 30
        expect(out.first[:days_to_long_term]).to be > 0
      end

      it 'does not flag a lot well outside the window' do
        positions = [position(
          symbol: 'X',
          lots: [lot(id: 'a', shares: 10, cost_basis: 100, acquired_at: (today - 100).iso8601)],
          current_price: 110.0
        )]
        expect(TaxHarvester.crossing_threshold(positions: positions)).to be_empty
      end

      it 'does not flag long-term lots' do
        positions = [position(
          symbol: 'X',
          lots: [lot(id: 'a', shares: 10, cost_basis: 100, acquired_at: (today - 800).iso8601)],
          current_price: 110.0
        )]
        expect(TaxHarvester.crossing_threshold(positions: positions)).to be_empty
      end

      it 'sorts by days-to-long-term ascending' do
        positions = [
          position(symbol: 'A', lots: [lot(id: 'a', shares: 1, cost_basis: 1, acquired_at: (today - 340).iso8601)], current_price: 1.0),
          position(symbol: 'B', lots: [lot(id: 'b', shares: 1, cost_basis: 1, acquired_at: (today - 360).iso8601)], current_price: 1.0)
        ]
        out = TaxHarvester.crossing_threshold(positions: positions)
        expect(out.map { |r| r[:symbol] }).to eq(%w[B A])
      end
    end

    describe '.ytd_summary' do
      it 'sums realised this year and reports cap-loss offset progress' do
        TradesStore.append({
          id: 'a1', date: today.iso8601, recorded_at: Time.now.utc.iso8601,
          symbol: 'A', side: 'sell', shares: 10, price: 90.0,
          realized_pl: -500.0, short_term_pl: -500.0, long_term_pl: 0.0, notes: 'ST loss'
        })
        TradesStore.append({
          id: 'b1', date: today.iso8601, recorded_at: Time.now.utc.iso8601,
          symbol: 'B', side: 'sell', shares: 10, price: 90.0,
          realized_pl: -2_800.0, short_term_pl: 0.0, long_term_pl: -2_800.0, notes: 'LT loss'
        })
        out = TaxHarvester.ytd_summary(trades: TradesStore.read)
        expect(out[:realized_short]).to eq(-500.0)
        expect(out[:realized_long]).to eq(-2_800.0)
        expect(out[:net]).to eq(-3_300.0)
        expect(out[:ordinary_offset_used]).to eq(3_000.0)
        expect(out[:ordinary_offset_remaining]).to eq(0.0)
        expect(out[:carryforward_estimate]).to eq(300.0)
      end

      it 'reports zero offset used when net is positive' do
        TradesStore.append({
          id: 'g1', date: today.iso8601, recorded_at: Time.now.utc.iso8601,
          symbol: 'A', side: 'sell', shares: 10, price: 110.0,
          realized_pl: 500.0, short_term_pl: 500.0, long_term_pl: 0.0, notes: 'gain'
        })
        out = TaxHarvester.ytd_summary(trades: TradesStore.read)
        expect(out[:net]).to eq(500.0)
        expect(out[:ordinary_offset_used]).to eq(0)
        expect(out[:ordinary_offset_remaining]).to eq(3_000.0)
      end

      it 'ignores last-year trades' do
        TradesStore.append({
          id: 'old', date: Date.new(today.year - 1, 6, 1).iso8601, recorded_at: Time.now.utc.iso8601,
          symbol: 'A', side: 'sell', shares: 10, price: 90.0,
          realized_pl: -1_000.0, short_term_pl: -1_000.0, long_term_pl: 0.0, notes: 'old'
        })
        out = TaxHarvester.ytd_summary(trades: TradesStore.read)
        expect(out[:net]).to eq(0.0)
      end
    end

    describe '.analyse' do
      it 'returns the full bundle keyed by :candidates / :crossing_threshold / :ytd / :totals' do
        positions = [position(
          symbol: 'X',
          lots: [lot(id: 'a', shares: 10, cost_basis: 100, acquired_at: two_years_ago)],
          current_price: 70.0
        )]
        result = TaxHarvester.analyse(positions: positions, profile: profile, trades: [])
        expect(result).to include(:profile, :candidates, :crossing_threshold, :ytd, :totals, :generated_at)
        expect(result[:totals][:lots_examined]).to eq(1)
        expect(result[:totals][:lots_with_loss]).to eq(1)
        expect(result[:totals][:total_unrealized_loss]).to eq(-300.0)
      end
    end
  end

  # ===========================================================================
  # Routes
  # ===========================================================================
  describe 'GET /portfolio/tax-harvest' do
    it 'renders the page with the empty-state messaging when nothing is configured' do
      get '/portfolio/tax-harvest'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('Tax-Loss Harvesting')
      expect(last_response.body).to include('Set up your profile')
      expect(last_response.body).to include('Decision support, not tax advice')
    end

    it 'renders the page after the profile is configured' do
      ProfileStore.update(current_age: 56, retirement_age: 63, risk_tolerance: 'moderate')
      get '/portfolio/tax-harvest'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('56')
      expect(last_response.body).to include('63')
      expect(last_response.body).to include('moderate')
    end

    it 'is reachable from /portfolio via a link' do
      get '/portfolio'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('/portfolio/tax-harvest')
    end
  end

  describe 'GET /api/portfolio/tax-harvest' do
    it 'returns a JSON analysis bundle' do
      get '/api/portfolio/tax-harvest'
      expect(last_response.status).to eq(200)
      json = JSON.parse(last_response.body)
      expect(json).to include('profile', 'candidates', 'crossing_threshold', 'ytd', 'totals')
    end
  end

  describe 'POST /profile' do
    it 'persists valid input and redirects back to the tax-harvest page' do
      post '/profile', current_age: '56', retirement_age: '63', risk_tolerance: 'aggressive',
                       federal_ltcg_rate: '0.20', federal_ordinary_rate: '0.32',
                       state_tax_rate: '', niit_applies: 'true',
                       return_to: '/portfolio/tax-harvest'
      expect(last_response.status).to eq(302)
      expect(last_response.headers['Location']).to include('/portfolio/tax-harvest')

      p = ProfileStore.read
      expect(p[:current_age]).to eq(56)
      expect(p[:retirement_age]).to eq(63)
      expect(p[:risk_tolerance]).to eq('aggressive')
      expect(p[:federal_ltcg_rate]).to eq(0.20)
      expect(p[:niit_applies]).to eq(true)
    end

    it 'redirects with profile_error when input is invalid' do
      post '/profile', current_age: '999'
      expect(last_response.status).to eq(302)
      expect(last_response.headers['Location']).to include('profile_error=')
    end
  end

  describe 'POST /api/profile' do
    it 'returns updated profile JSON for valid input' do
      post '/api/profile', { current_age: 40 }.to_json,
           { 'CONTENT_TYPE' => 'application/json' }
      expect(last_response.status).to eq(200)
      json = JSON.parse(last_response.body)
      expect(json['current_age']).to eq(40)
    end

    it 'returns 400 with error JSON for invalid input' do
      post '/api/profile', { risk_tolerance: 'reckless' }.to_json,
           { 'CONTENT_TYPE' => 'application/json' }
      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body)).to include('error')
    end
  end
end
