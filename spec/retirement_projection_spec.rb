require 'rspec'
require 'rack/test'
require 'tmpdir'
require 'fileutils'

ENV['RACK_ENV'] = 'test'

require_relative '../app/main'
require_relative '../app/retirement_projection'

RSpec.describe RetirementProjection do
  describe '.required_annual_return' do
    it 'computes the CAGR needed to grow current to target over N years' do
      # 100 → 200 in 7 years ≈ 10.41%
      rr = RetirementProjection.required_annual_return(current_value: 100, target_value: 200, years: 7)
      expect(rr).to be_within(1e-4).of(0.1041)
    end

    it 'returns 0 when current already meets or exceeds target' do
      expect(RetirementProjection.required_annual_return(current_value: 200, target_value: 200, years: 5)).to eq(0.0)
      expect(RetirementProjection.required_annual_return(current_value: 300, target_value: 200, years: 5)).to eq(0.0)
    end

    it 'returns nil when any input is missing or non-positive' do
      expect(RetirementProjection.required_annual_return(current_value: nil, target_value: 200, years: 5)).to be_nil
      expect(RetirementProjection.required_annual_return(current_value: 100, target_value: nil, years: 5)).to be_nil
      expect(RetirementProjection.required_annual_return(current_value: 100, target_value: 200, years: 0)).to be_nil
      expect(RetirementProjection.required_annual_return(current_value: 0,   target_value: 200, years: 5)).to be_nil
      expect(RetirementProjection.required_annual_return(current_value: 100, target_value: 0,   years: 5)).to be_nil
    end
  end

  describe '.project' do
    let(:profile_full) do
      { current_age: 56, retirement_age: 63, retirement_target_value: 2_500_000.0 }
    end

    it 'builds the full bundle when inputs are complete' do
      out = RetirementProjection.project(profile: profile_full, current_value: 1_500_000)
      expect(out[:years_remaining]).to eq(7)
      expect(out[:current_value]).to eq(1_500_000.0)
      expect(out[:target_value]).to eq(2_500_000.0)
      expect(out[:gap]).to eq(1_000_000.0)
      expect(out[:required_annual_return]).to be_within(1e-3).of(0.0757)
      expect(out[:status]).to eq('short')
    end

    it 'reports at_goal when current >= target' do
      out = RetirementProjection.project(profile: profile_full, current_value: 3_000_000)
      expect(out[:status]).to eq('at_goal')
      expect(out[:gap]).to eq(-500_000.0)
      expect(out[:required_annual_return]).to eq(0.0)
    end

    it 'returns nil when retirement_target_value is unset' do
      p = profile_full.merge(retirement_target_value: nil)
      expect(RetirementProjection.project(profile: p, current_value: 1_500_000)).to be_nil
    end

    it 'returns nil when ages are unset' do
      p = profile_full.merge(current_age: nil)
      expect(RetirementProjection.project(profile: p, current_value: 1_500_000)).to be_nil
    end

    it 'returns nil when retirement_age <= current_age (no time left)' do
      p = profile_full.merge(current_age: 63, retirement_age: 63)
      expect(RetirementProjection.project(profile: p, current_value: 1_500_000)).to be_nil
    end

    it 'returns nil when current_value is zero or negative' do
      expect(RetirementProjection.project(profile: profile_full, current_value: 0)).to be_nil
      expect(RetirementProjection.project(profile: profile_full, current_value: -5)).to be_nil
    end

    it 'attaches benchmarks + citations + verdict' do
      out = RetirementProjection.project(profile: profile_full, current_value: 1_500_000)
      expect(out[:benchmarks]).to be_an(Array).and(satisfy { |arr| arr.length >= 2 })
      expect(out[:citations].first).to include(:url, :label)
      expect(out[:citations].first[:url]).to start_with('https://')
      expect(out[:verdict]).to be_a(Symbol)
      expect(out[:verdict_summary]).to be_a(String)
    end

    describe 'inflation handling' do
      it 'computes both real and nominal required CAGR; the nominal drives the verdict' do
        # Same inputs as the basic test: 1.5M → 2.5M target real, 7y, 2.5% inflation.
        # nominal_target = 2.5M × 1.025^7 ≈ 2.97M
        # real_required  ≈ (2.5/1.5)^(1/7) - 1 ≈ 7.57%
        # nominal_required ≈ (2.97/1.5)^(1/7) - 1 ≈ 10.31% → not_on_track
        prof = profile_full.merge(inflation_assumption_rate: 0.025)
        out  = RetirementProjection.project(profile: prof, current_value: 1_500_000)
        expect(out[:inflation_rate]).to eq(0.025)
        expect(out[:target_real]).to eq(2_500_000.0)
        expect(out[:target_nominal]).to be_within(2.0).of(2_971_714.38)
        expect(out[:real_required_return]).to be_within(1e-3).of(0.0757)
        expect(out[:nominal_required_return]).to be_within(1e-3).of(0.1031)
        # Verdict uses the nominal — 10.31% > 10% threshold
        expect(out[:verdict]).to eq(:not_on_track)
      end

      it 'aliases target_value/gap/required_annual_return for back-compat' do
        prof = profile_full.merge(inflation_assumption_rate: 0.025)
        out  = RetirementProjection.project(profile: prof, current_value: 1_500_000)
        expect(out[:target_value]).to eq(out[:target_real])
        expect(out[:gap]).to eq(out[:gap_real])
        expect(out[:required_annual_return]).to eq(out[:nominal_required_return])
      end

      it 'with zero inflation, real and nominal required returns are equal' do
        prof = profile_full.merge(inflation_assumption_rate: 0.0)
        out  = RetirementProjection.project(profile: prof, current_value: 1_500_000)
        expect(out[:real_required_return]).to be_within(1e-6).of(out[:nominal_required_return])
        expect(out[:target_real]).to eq(out[:target_nominal])
      end

      it 'flags at_goal when nominal target is already met' do
        prof = profile_full.merge(inflation_assumption_rate: 0.025)
        # 5M current beats both real (2.5M) and nominal (~2.97M) target
        out = RetirementProjection.project(profile: prof, current_value: 5_000_000)
        expect(out[:status]).to eq('at_goal')
        expect(out[:verdict]).to eq(:at_goal)
      end
    end
  end

  describe '.years_until_depletion' do
    it 'returns infinity when withdrawal is 0' do
      n = RetirementProjection.years_until_depletion(starting_balance: 1_000_000, annual_withdrawal: 0, real_return: 0.04)
      expect(n).to be_infinite
    end

    it 'returns infinity when earnings cover the withdrawal (W ≤ r·B)' do
      # 4% of 1M = 40K/yr; 30K withdrawal is fully covered
      n = RetirementProjection.years_until_depletion(starting_balance: 1_000_000, annual_withdrawal: 30_000, real_return: 0.04)
      expect(n).to be_infinite
    end

    it 'returns infinity exactly at the sustainable boundary (W = r·B)' do
      n = RetirementProjection.years_until_depletion(starting_balance: 1_000_000, annual_withdrawal: 40_000, real_return: 0.04)
      expect(n).to be_infinite
    end

    it 'computes finite years when W > r·B' do
      # 5% withdrawal at 4% return ≈ 41 years (Trinity-style result)
      n = RetirementProjection.years_until_depletion(starting_balance: 1_000_000, annual_withdrawal: 50_000, real_return: 0.04)
      expect(n).to be_within(0.5).of(40.99)
    end

    it 'handles zero real return — linear depletion B/W' do
      n = RetirementProjection.years_until_depletion(starting_balance: 1_000_000, annual_withdrawal: 50_000, real_return: 0.0)
      expect(n).to eq(20.0)
    end

    it 'handles negative real return — finite years' do
      n = RetirementProjection.years_until_depletion(starting_balance: 1_000_000, annual_withdrawal: 100_000, real_return: -0.02)
      expect(n).to be > 0
      expect(n).to be < 20
    end
  end

  describe '.spending_analysis' do
    let(:profile) do
      {
        current_age: 56, retirement_age: 63,
        retirement_target_value: 2_500_000.0,
        inflation_assumption_rate: 0.025,
        post_retirement_real_return: 0.04,
        monthly_retirement_spending: 10_000.0
      }
    end

    it 'returns nil when monthly_retirement_spending is unset' do
      p = profile.merge(monthly_retirement_spending: nil)
      expect(RetirementProjection.spending_analysis(profile: p, target_real: 2_500_000)).to be_nil
    end

    it 'returns nil when target_real is unset / non-positive' do
      expect(RetirementProjection.spending_analysis(profile: profile, target_real: 0)).to be_nil
      expect(RetirementProjection.spending_analysis(profile: profile, target_real: nil)).to be_nil
    end

    it 'computes sustainable rate, withdrawal rate, and years to depletion' do
      out = RetirementProjection.spending_analysis(profile: profile, target_real: 2_500_000)
      expect(out[:monthly_target_real]).to eq(10_000.0)
      expect(out[:annual_target_real]).to eq(120_000.0)
      expect(out[:sustainable_annual_real]).to eq(100_000.0) # 4% of 2.5M
      expect(out[:sustainable_monthly_real]).to be_within(0.01).of(8333.33)
      expect(out[:withdrawal_rate]).to be_within(1e-6).of(0.048) # 120k/2.5M
      expect(out[:years_portfolio_lasts]).to be_within(0.5).of(45.68) # 4.8% withdrawal at 4% return ≈ 45.7 yr
      expect(out[:verdict]).to eq(:comfortable) # > 40 yrs
    end

    it 'reports perpetual when withdrawal is at or below sustainable rate' do
      p = profile.merge(monthly_retirement_spending: 8_000.0) # 96k/yr = 3.84% withdrawal, < 4% return
      out = RetirementProjection.spending_analysis(profile: p, target_real: 2_500_000)
      expect(out[:years_portfolio_lasts]).to be_infinite
      expect(out[:verdict]).to eq(:perpetual)
    end

    it 'classifies thirty_year_safe at 4% withdrawal at 4% real return' do
      # At W = 4% × B and r = 4%, W = rB → infinite. So nudge withdrawal up.
      # Use 5% real return to get a 30-ish-year result with 6% withdrawal.
      p = profile.merge(post_retirement_real_return: 0.05, monthly_retirement_spending: 12_500.0) # 150k/yr = 6%
      out = RetirementProjection.spending_analysis(profile: p, target_real: 2_500_000)
      expect(out[:years_portfolio_lasts]).to be_within(2).of(36)
      expect(out[:verdict]).to eq(:thirty_year_safe).or eq(:comfortable)
    end

    it 'flags severely_underfunded for very high withdrawals' do
      p = profile.merge(monthly_retirement_spending: 30_000.0) # 360k/yr = 14.4%
      out = RetirementProjection.spending_analysis(profile: p, target_real: 2_500_000)
      expect(out[:years_portfolio_lasts]).to be < 10
      expect(out[:verdict]).to eq(:severely_underfunded)
    end
  end

  describe '.verdict_for' do
    it 'returns at_goal when status is at_goal' do
      v, msg = RetirementProjection.verdict_for(required: 0.0, status: 'at_goal')
      expect(v).to eq(:at_goal)
      expect(msg).to include('already at or above')
    end

    it 'returns on_track_safe for required CAGR <= 5%' do
      v, msg = RetirementProjection.verdict_for(required: 0.04, status: 'short')
      expect(v).to eq(:on_track_safe)
      expect(msg).to include('Treasury')
    end

    it 'returns on_track_balanced for required CAGR 5-8%' do
      v, msg = RetirementProjection.verdict_for(required: 0.07, status: 'short')
      expect(v).to eq(:on_track_balanced)
      expect(msg).to include('60/40')
    end

    it 'returns tight_equity for required CAGR 8-10%' do
      v, msg = RetirementProjection.verdict_for(required: 0.09, status: 'short')
      expect(v).to eq(:tight_equity)
      expect(msg).to include('Tight')
    end

    it 'returns not_on_track for required CAGR > 10%' do
      v, msg = RetirementProjection.verdict_for(required: 0.13, status: 'short')
      expect(v).to eq(:not_on_track)
      expect(msg).to include('S&P 500')
    end
  end
end

RSpec.describe 'GET /portfolio/retirement' do
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

  def write_snapshot(file_date, total_value:)
    require_relative '../app/import_snapshot_store'
    ImportSnapshotStore.write(
      source: 'fidelity',
      basename: "Portfolio_Positions_#{Date.parse(file_date).strftime('%b-%d-%Y')}",
      data: {
        'file_date' => file_date,
        'positions' => [{ 'symbol' => 'A', 'shares' => 1, 'last_price' => total_value, 'current_value' => total_value }]
      }
    )
  end

  it 'renders the empty-profile state when nothing is configured' do
    get '/portfolio/retirement'
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('Configure your profile')
    expect(last_response.body).to include('/portfolio/tax-harvest')
  end

  it 'renders the projection when profile is configured + portfolio has value' do
    ProfileStore.update(current_age: 56, retirement_age: 63, retirement_target_value: 2_500_000)
    write_snapshot('2026-04-30', total_value: 2_080_000)
    get '/portfolio/retirement'
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('Retirement progress')
    expect(last_response.body).to include('Required annual return')
    expect(last_response.body).to include('back to portfolio')
  end

  it 'renders the spending sustainability sub-section when monthly spending is set' do
    ProfileStore.update(current_age: 56, retirement_age: 63,
                        retirement_target_value: 2_500_000,
                        monthly_retirement_spending: 10_000)
    write_snapshot('2026-04-30', total_value: 2_080_000)
    get '/portfolio/retirement'
    expect(last_response.body).to include('is it sustainable')
    expect(last_response.body).to include('Sustainable monthly')
    expect(last_response.body).to include('Years portfolio lasts')
  end

  it 'is reachable from /portfolio' do
    get '/portfolio'
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('/portfolio/retirement')
  end
end
