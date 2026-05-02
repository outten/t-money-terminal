require 'rspec'
require_relative '../app/expense_ratio_map'

RSpec.describe ExpenseRatioMap do
  describe '.for_symbol' do
    it 'returns the curated ratio for known popular ETFs' do
      expect(ExpenseRatioMap.for_symbol('VOO')).to be_within(1e-6).of(0.0003)
      expect(ExpenseRatioMap.for_symbol('SPY')).to be_within(1e-6).of(0.0009)
      expect(ExpenseRatioMap.for_symbol('QQQ')).to be_within(1e-6).of(0.0020)
      expect(ExpenseRatioMap.for_symbol('BND')).to be_within(1e-6).of(0.0003)
    end

    it 'covers the user’s actual top holdings (target-date, active funds, VIP)' do
      expect(ExpenseRatioMap.for_symbol('FFTHX')).to be_within(1e-6).of(0.0075)
      expect(ExpenseRatioMap.for_symbol('TRRJX')).to be_within(1e-6).of(0.0059)
      expect(ExpenseRatioMap.for_symbol('LFEAX')).to be_within(1e-6).of(0.0074)
      expect(ExpenseRatioMap.for_symbol('FMAGX')).to be_within(1e-6).of(0.0055)
      expect(ExpenseRatioMap.for_symbol('FXVLT')).to be_within(1e-6).of(0.0012)
    end

    it 'covers institutional fund-class CUSIPs (401k plan holdings)' do
      expect(ExpenseRatioMap.for_symbol('84679Q106')).to be_within(1e-6).of(0.0002)
      expect(ExpenseRatioMap.for_symbol('20030Q609')).to be_within(1e-6).of(0.0005)
    end

    it 'is case-insensitive' do
      expect(ExpenseRatioMap.for_symbol('voo')).to eq(ExpenseRatioMap.for_symbol('VOO'))
    end

    it 'returns nil for unknown symbols' do
      expect(ExpenseRatioMap.for_symbol('ZZZZZ')).to be_nil
      expect(ExpenseRatioMap.for_symbol('')).to be_nil
      expect(ExpenseRatioMap.for_symbol(nil)).to be_nil
    end
  end

  describe '.known?' do
    it 'returns true for symbols in the map and false otherwise' do
      expect(ExpenseRatioMap.known?('VOO')).to eq(true)
      expect(ExpenseRatioMap.known?('NOPE')).to eq(false)
    end
  end

  describe '.coverage_count' do
    it 'is a positive integer' do
      expect(ExpenseRatioMap.coverage_count).to be > 50
    end
  end
end
