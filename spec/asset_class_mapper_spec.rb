require 'rspec'
require_relative '../app/asset_class_mapper'

RSpec.describe AssetClassMapper do
  describe '.classify' do
    it 'maps explicit symbols from the curated list' do
      expect(AssetClassMapper.classify(symbol: 'SPY')).to eq('us_stocks')
      expect(AssetClassMapper.classify(symbol: 'BND')).to eq('bonds')
      expect(AssetClassMapper.classify(symbol: 'VNQ')).to eq('real_estate')
      expect(AssetClassMapper.classify(symbol: 'GLD')).to eq('commodities')
      expect(AssetClassMapper.classify(symbol: 'SPAXX')).to eq('cash')
      expect(AssetClassMapper.classify(symbol: 'FFTHX')).to eq('target_date')
      expect(AssetClassMapper.classify(symbol: 'FPADX')).to eq('intl_stocks')
    end

    it 'is case-insensitive on the symbol' do
      expect(AssetClassMapper.classify(symbol: 'spy')).to eq('us_stocks')
    end

    it 'falls through to description regex for unknown symbols' do
      expect(AssetClassMapper.classify(symbol: 'XYZ', description: 'FIDELITY FREEDOM 2035')).to eq('target_date')
      expect(AssetClassMapper.classify(symbol: 'XYZ', description: 'VANGUARD TARGET 2040')).to eq('target_date')
      expect(AssetClassMapper.classify(symbol: 'XYZ', description: 'T ROWE PRICE RETIREMENT 2030 FUND')).to eq('target_date')
    end

    it 'classifies international funds via description' do
      expect(AssetClassMapper.classify(symbol: 'XYZ', description: 'SP TTL INTL IDX CL G')).to eq('intl_stocks')
      expect(AssetClassMapper.classify(symbol: 'XYZ', description: 'EMERGING MARKETS INDEX FUND')).to eq('intl_stocks')
      expect(AssetClassMapper.classify(symbol: 'XYZ', description: 'INTERNATIONAL VALUE')).to eq('intl_stocks')
    end

    it 'classifies US broad equity via description' do
      expect(AssetClassMapper.classify(symbol: 'XYZ', description: 'SP 500 INDEX PL CL G')).to eq('us_stocks')
      expect(AssetClassMapper.classify(symbol: 'XYZ', description: 'S&P 500 INDEX')).to eq('us_stocks')
      expect(AssetClassMapper.classify(symbol: 'XYZ', description: 'TOTAL MARKET INDEX')).to eq('us_stocks')
      expect(AssetClassMapper.classify(symbol: 'XYZ', description: 'FIDELITY LARGE CAP STOCK')).to eq('us_stocks')
      expect(AssetClassMapper.classify(symbol: 'XYZ', description: 'CONTRAFUND')).to eq('us_stocks')
    end

    it 'classifies bonds via description' do
      expect(AssetClassMapper.classify(symbol: 'XYZ', description: 'TOTAL BOND MARKET')).to eq('bonds')
      expect(AssetClassMapper.classify(symbol: 'XYZ', description: '10 YEAR TREASURY')).to eq('bonds')
      expect(AssetClassMapper.classify(symbol: 'XYZ', description: 'MUNI BOND FUND')).to eq('bonds')
      expect(AssetClassMapper.classify(symbol: 'XYZ', description: 'HIGH-YIELD CORPORATE')).to eq('bonds')
    end

    it 'classifies real estate via description' do
      expect(AssetClassMapper.classify(symbol: 'XYZ', description: 'VANGUARD REAL ESTATE INDEX')).to eq('real_estate')
      expect(AssetClassMapper.classify(symbol: 'XYZ', description: 'REIT INCOME FUND')).to eq('real_estate')
    end

    it 'classifies commodities via description' do
      expect(AssetClassMapper.classify(symbol: 'XYZ', description: 'SPDR GOLD TRUST')).to eq('commodities')
      expect(AssetClassMapper.classify(symbol: 'XYZ', description: 'SILVER ETF')).to eq('commodities')
    end

    it 'classifies cash via description' do
      expect(AssetClassMapper.classify(symbol: 'XYZ', description: 'GOVT CASH RESERVES')).to eq('cash')
      expect(AssetClassMapper.classify(symbol: 'XYZ', description: 'MONEY MARKET')).to eq('cash')
    end

    it 'classifies balanced funds (after target-date)' do
      expect(AssetClassMapper.classify(symbol: 'XYZ', description: 'Fidelity VIP Balanced')).to eq('balanced')
    end

    it 'returns unmapped for unknown symbol + description' do
      expect(AssetClassMapper.classify(symbol: 'ZZZZZ', description: '')).to eq('unmapped')
      expect(AssetClassMapper.classify(symbol: 'ZZZZZ', description: 'Some random fund')).to eq('unmapped')
    end

    it 'handles missing description without crashing' do
      expect(AssetClassMapper.classify(symbol: 'ZZZZZ')).to eq('unmapped')
      expect(AssetClassMapper.classify(symbol: 'ZZZZZ', description: nil)).to eq('unmapped')
    end

    it 'prioritises target-date over balanced when description matches both' do
      # An imaginary "balanced retirement 2035" — target_date wins because the
      # year-targeted glide-path is the more specific signal.
      expect(AssetClassMapper.classify(symbol: 'XYZ', description: 'BALANCED RETIREMENT 2035')).to eq('target_date')
    end

    it 'classifies ADRs as intl_stocks (not us_stocks) via SPON ADS / ADS EA REP markers' do
      expect(AssetClassMapper.classify(symbol: 'ZZZ', description: 'TAIWAN SEMICONDUCTOR MANUFACTURING SPON ADS EACH REP 5 ORD')).to eq('intl_stocks')
      expect(AssetClassMapper.classify(symbol: 'ZZZ', description: 'SHELL PLC SPON ADS EA REP 2 ORD SHS')).to eq('intl_stocks')
    end

    it 'classifies individual US common stocks via description suffixes' do
      expect(AssetClassMapper.classify(symbol: 'ZZZ', description: 'NVIDIA CORPORATION COM')).to eq('us_stocks')
      expect(AssetClassMapper.classify(symbol: 'ZZZ', description: 'ALPHABET INC CAP STK CL A')).to eq('us_stocks')
      expect(AssetClassMapper.classify(symbol: 'ZZZ', description: 'AMAZON.COM INC')).to eq('us_stocks')
      expect(AssetClassMapper.classify(symbol: 'ZZZ', description: 'META PLATFORMS INC CLASS A COMMON STOCK')).to eq('us_stocks')
      expect(AssetClassMapper.classify(symbol: 'ZZZ', description: 'BROADCOM INC COM')).to eq('us_stocks')
    end

    it 'recognises Fidelity active equity funds by name (Magellan, Blue Chip, Value Discovery, Multifactor)' do
      expect(AssetClassMapper.classify(symbol: 'ZZZ', description: 'FIDELITY MAGELLAN')).to eq('us_stocks')
      expect(AssetClassMapper.classify(symbol: 'ZZZ', description: 'FIDELITY BLUE CHIP GROWTH')).to eq('us_stocks')
      expect(AssetClassMapper.classify(symbol: 'ZZZ', description: 'FIDELITY VALUE DISCOVERY')).to eq('us_stocks')
      expect(AssetClassMapper.classify(symbol: 'ZZZ', description: 'FIDELITY SML MID MLTFCT')).to eq('us_stocks')
    end

    it 'INTL / INTNL / EMNG MKT abbreviations route to intl_stocks' do
      expect(AssetClassMapper.classify(symbol: 'ZZZ', description: 'FID SAI INTNL LOW VOLATILITY INDEX FD')).to eq('intl_stocks')
      expect(AssetClassMapper.classify(symbol: 'ZZZ', description: 'ISHARES INC EMNG MKTS EQT')).to eq('intl_stocks')
    end
  end

  describe '.breakdown' do
    it 'sums values per class and reports percentages' do
      positions = [
        { 'symbol' => 'SPY', 'description' => '', 'current_value' => 1000 },
        { 'symbol' => 'VOO', 'description' => '', 'current_value' => 500 },
        { 'symbol' => 'BND', 'description' => '', 'current_value' => 500 }
      ]
      out = AssetClassMapper.breakdown(positions)
      total_pct = out.sum { |r| r[:pct] }
      expect(total_pct).to be_within(1e-6).of(1.0)
      us = out.find { |r| r[:class] == 'us_stocks' }
      bd = out.find { |r| r[:class] == 'bonds' }
      expect(us[:value]).to eq(1500.0)
      expect(us[:count]).to eq(2)
      expect(us[:pct]).to be_within(1e-6).of(0.75)
      expect(bd[:value]).to eq(500.0)
      expect(bd[:pct]).to be_within(1e-6).of(0.25)
    end

    it 'sorts rows by value descending' do
      positions = [
        { 'symbol' => 'BND', 'description' => '', 'current_value' => 100 },
        { 'symbol' => 'SPY', 'description' => '', 'current_value' => 1000 },
        { 'symbol' => 'GLD', 'description' => '', 'current_value' => 500 }
      ]
      out = AssetClassMapper.breakdown(positions)
      expect(out.map { |r| r[:class] }).to eq(%w[us_stocks commodities bonds])
    end

    it 'top symbols within each class are sorted by value' do
      positions = [
        { 'symbol' => 'VTI', 'description' => '', 'current_value' => 50 },
        { 'symbol' => 'SPY', 'description' => '', 'current_value' => 200 },
        { 'symbol' => 'QQQ', 'description' => '', 'current_value' => 100 }
      ]
      out = AssetClassMapper.breakdown(positions)
      us = out.find { |r| r[:class] == 'us_stocks' }
      expect(us[:symbols].map { |s| s[:symbol] }).to eq(%w[SPY QQQ VTI])
    end

    it 'skips zero / negative value positions' do
      positions = [
        { 'symbol' => 'SPY', 'current_value' => 0 },
        { 'symbol' => 'BND', 'current_value' => 100 }
      ]
      out = AssetClassMapper.breakdown(positions)
      expect(out.length).to eq(1)
      expect(out.first[:class]).to eq('bonds')
    end

    it 'falls back to shares × last_price when current_value is missing' do
      positions = [
        { 'symbol' => 'BND', 'shares' => 10, 'last_price' => 80 }
      ]
      out = AssetClassMapper.breakdown(positions)
      expect(out.first[:value]).to eq(800.0)
    end

    it 'returns [] for empty input' do
      expect(AssetClassMapper.breakdown([])).to eq([])
      expect(AssetClassMapper.breakdown(nil)).to eq([])
    end
  end

  describe '.class_label' do
    it 'returns human labels for known classes' do
      expect(AssetClassMapper.class_label('us_stocks')).to eq('US stocks')
      expect(AssetClassMapper.class_label('target_date')).to eq('Target-date / glide-path')
      expect(AssetClassMapper.class_label('unmapped')).to eq('Unmapped')
    end

    it 'returns the raw class for unknown labels (defensive)' do
      expect(AssetClassMapper.class_label('something_new')).to eq('something_new')
    end
  end
end
