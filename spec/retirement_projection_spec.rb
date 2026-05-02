require 'rspec'
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
