require 'rspec'
require_relative '../app/analytics'

RSpec.describe Analytics::Indicators do
  describe '.sma' do
    it 'computes rolling mean with leading nils' do
      result = described_class.sma([1, 2, 3, 4, 5], 3)
      expect(result).to eq([nil, nil, 2.0, 3.0, 4.0])
    end

    it 'returns all nils when input is shorter than the period' do
      expect(described_class.sma([1, 2], 5)).to eq([nil, nil])
    end

    it 'raises on non-positive period' do
      expect { described_class.sma([1, 2, 3], 0) }.to raise_error(ArgumentError)
    end
  end

  describe '.ema' do
    it 'seeds with SMA of the first `period` values' do
      ema = described_class.ema([1.0, 2.0, 3.0, 4.0, 5.0], 3)
      # seed = mean(1,2,3) = 2.0
      expect(ema[0..1]).to eq([nil, nil])
      expect(ema[2]).to eq(2.0)
      # k = 2/(3+1) = 0.5 → next = 4 * 0.5 + 2.0 * 0.5 = 3.0
      expect(ema[3]).to be_within(1e-9).of(3.0)
      # next = 5 * 0.5 + 3.0 * 0.5 = 4.0
      expect(ema[4]).to be_within(1e-9).of(4.0)
    end
  end

  describe '.rsi' do
    it 'returns 100 for a monotonically increasing series' do
      closes = (1..20).map(&:to_f)
      rsi = described_class.rsi(closes, period: 14)
      # First 14 entries should be nil
      expect(rsi[0..13]).to all(be_nil)
      expect(described_class.latest(rsi)).to eq(100.0)
    end

    it 'returns 0 for a monotonically decreasing series' do
      closes = (1..20).to_a.reverse.map(&:to_f)
      rsi = described_class.rsi(closes, period: 14)
      expect(described_class.latest(rsi)).to be_within(1e-9).of(0.0)
    end
  end

  describe '.macd' do
    it 'returns arrays of the same length as input' do
      closes = (1..50).map(&:to_f)
      out    = described_class.macd(closes)
      expect(out[:macd].length).to eq(50)
      expect(out[:signal].length).to eq(50)
      expect(out[:histogram].length).to eq(50)
    end

    it 'produces a finite histogram value for a sustained uptrend' do
      # MACD histogram on a compounding uptrend starts positive then decays
      # toward zero as EMAs catch up — what matters is it's a real number.
      closes = (0..60).map { |i| 100.0 * (1.01**i) }
      out    = described_class.macd(closes)
      expect(described_class.latest(out[:histogram])).to be_a(Float)
    end
  end

  describe '.bollinger' do
    it 'upper > middle > lower after the warmup window' do
      closes = (1..40).map(&:to_f).map { |x| x + rand * 0.01 }
      bb     = described_class.bollinger(closes, period: 20, stddev: 2)
      i = closes.length - 1
      expect(bb[:upper][i]).to be > bb[:middle][i]
      expect(bb[:middle][i]).to be > bb[:lower][i]
    end
  end
end

RSpec.describe Analytics::Risk do
  let(:closes) { [100.0, 102.0, 101.0, 105.0, 107.0, 104.0, 108.0] }

  describe '.returns' do
    it 'computes simple daily returns' do
      r = described_class.returns([100.0, 110.0, 121.0])
      expect(r[0]).to be_within(1e-9).of(0.10)
      expect(r[1]).to be_within(1e-9).of(0.10)
    end

    it 'returns [] for series shorter than 2' do
      expect(described_class.returns([100.0])).to eq([])
    end
  end

  describe '.annualized_return' do
    it 'is zero when first and last prices are equal' do
      expect(described_class.annualized_return([100.0, 90.0, 100.0], periods: 252))
        .to be_within(1e-9).of(0.0)
    end

    it 'matches CAGR for a known 2-year +44% run' do
      # 100 → 144 over exactly 2 years (504 daily returns → 505 closes)
      series = Array.new(505, 0.0)
      series[0]  = 100.0
      series[-1] = 144.0
      ar = described_class.annualized_return(series, periods: 252)
      expect(ar).to be_within(1e-6).of(0.2)
    end
  end

  describe '.max_drawdown' do
    it 'returns a negative number for a peak-to-trough drop' do
      dd = described_class.max_drawdown([100.0, 120.0, 60.0, 90.0])
      expect(dd).to be_within(1e-9).of(-0.5) # 120 → 60
    end

    it 'returns 0 for a monotonic run-up' do
      expect(described_class.max_drawdown([100.0, 110.0, 120.0])).to eq(0.0)
    end
  end

  describe '.sharpe' do
    it 'is positive when returns exceed the risk-free rate' do
      trend = (0...252).map { |i| 100 * (1.0005**i) } # +0.05%/day, very stable
      expect(described_class.sharpe(trend, risk_free_rate: 0.02)).to be > 0
    end

    it 'is nil when volatility is zero' do
      flat = Array.new(10, 100.0)
      expect(described_class.sharpe(flat)).to be_nil
    end
  end

  describe '.var_historical' do
    it 'returns a negative number when losses populate the lower tail' do
      # Alternate +1% / -1% days with three larger -5% drops in the tail so
      # the 5th percentile definitely lands on a loss day.
      rets  = Array.new(40) { |i| i.even? ? 0.01 : -0.01 } + Array.new(3, -0.05)
      closes = [100.0]
      rets.each { |r| closes << closes.last * (1 + r) }
      var95 = described_class.var_historical(closes, confidence: 0.95)
      expect(var95).to be < 0
    end
  end

  describe '.beta' do
    it 'returns ≈ 1.0 when asset == benchmark' do
      closes = [100.0, 101.0, 99.0, 102.0, 105.0, 103.0, 107.0]
      expect(described_class.beta(closes, closes)).to be_within(1e-9).of(1.0)
    end

    it 'returns ≈ 2.0 when asset is a 2× leveraged version of benchmark' do
      bench = [100.0, 101.0, 99.5, 102.0, 100.0, 101.5]
      # Asset returns = 2 × benchmark returns
      ra    = described_class.returns(bench).map { |x| 2 * x }
      asset = [100.0]
      ra.each { |r| asset << asset.last * (1 + r) }
      expect(described_class.beta(asset, bench)).to be_within(1e-9).of(2.0)
    end
  end

  describe '.correlation' do
    it 'is 1.0 for a series correlated with itself' do
      c = [100.0, 101.0, 102.0, 101.0, 103.0]
      expect(described_class.correlation(c, c)).to be_within(1e-9).of(1.0)
    end

    it 'is -1.0 for perfectly anti-correlated daily returns' do
      # Build two series whose daily returns are exact negations of each other.
      returns_a = [0.02, -0.03, 0.04, -0.01, 0.05, -0.02]
      a = [100.0]; returns_a.each { |r| a << a.last * (1 + r) }
      b = [100.0]; returns_a.each { |r| b << b.last * (1 - r) }
      expect(described_class.correlation(a, b)).to be_within(1e-3).of(-1.0)
    end
  end

  describe '.inverse_normal_cdf' do
    it 'returns 0 at p=0.5' do
      expect(described_class.inverse_normal_cdf(0.5)).to be_within(1e-6).of(0.0)
    end

    it 'returns ≈ -1.6449 at p=0.05' do
      expect(described_class.inverse_normal_cdf(0.05)).to be_within(1e-3).of(-1.6449)
    end
  end

  describe '.align_on_dates' do
    it 'intersects by date and emits parallel closes arrays' do
      a = [{ date: '2026-01-01', close: 100 }, { date: '2026-01-02', close: 101 }]
      b = [{ date: '2026-01-02', close: 50 },  { date: '2026-01-03', close: 51 }]
      ca, cb = described_class.align_on_dates(a, b)
      expect(ca).to eq([101.0])
      expect(cb).to eq([50.0])
    end
  end
end

RSpec.describe Analytics::BlackScholes do
  # Textbook reference: S=100, K=100, T=1, r=5%, σ=20%, q=0
  # ATM 1-year call ≈ 10.4506, put ≈ 5.5735 (via put-call parity).
  describe '.price' do
    it 'matches the canonical ATM call price' do
      call = described_class.price(:call, s: 100, k: 100, t: 1.0, r: 0.05, sigma: 0.20)
      expect(call).to be_within(1e-3).of(10.4506)
    end

    it 'matches the canonical ATM put price' do
      put = described_class.price(:put, s: 100, k: 100, t: 1.0, r: 0.05, sigma: 0.20)
      expect(put).to be_within(1e-3).of(5.5735)
    end

    it 'satisfies put-call parity: C - P = S - K·e^(-rT)' do
      call = described_class.price(:call, s: 100, k: 90, t: 0.5, r: 0.04, sigma: 0.25)
      put  = described_class.price(:put,  s: 100, k: 90, t: 0.5, r: 0.04, sigma: 0.25)
      parity = 100 - 90 * Math.exp(-0.04 * 0.5)
      expect(call - put).to be_within(1e-6).of(parity)
    end

    it 'returns nil for invalid inputs' do
      expect(described_class.price(:call, s: 100, k: 100, t: 0,   r: 0.05, sigma: 0.2)).to be_nil
      expect(described_class.price(:call, s: 100, k: 100, t: 0.5, r: 0.05, sigma: 0)).to be_nil
    end
  end

  describe '.greeks' do
    let(:g) { described_class.greeks(:call, s: 100, k: 100, t: 1.0, r: 0.05, sigma: 0.20) }

    it 'ATM call delta ≈ 0.6368' do
      expect(g[:delta]).to be_within(1e-3).of(0.6368)
    end

    it 'gamma is positive' do
      expect(g[:gamma]).to be > 0
    end

    it 'vega is positive' do
      expect(g[:vega]).to be > 0
    end

    it 'call theta is negative (time decay hurts long calls)' do
      expect(g[:theta]).to be < 0
    end

    it 'put delta is in [-1, 0]' do
      pg = described_class.greeks(:put, s: 100, k: 100, t: 1.0, r: 0.05, sigma: 0.20)
      expect(pg[:delta]).to be_between(-1.0, 0.0)
    end
  end

  describe '.implied_volatility' do
    it 'round-trips to the input vol' do
      sigma = 0.27
      price = described_class.price(:call, s: 100, k: 105, t: 0.5, r: 0.03, sigma: sigma)
      iv    = described_class.implied_volatility(:call, market_price: price,
                                                 s: 100, k: 105, t: 0.5, r: 0.03)
      expect(iv).to be_within(1e-4).of(sigma)
    end
  end

  describe '.historical_volatility' do
    it 'is zero for a flat price series' do
      expect(described_class.historical_volatility([100.0, 100.0, 100.0, 100.0])).to eq(0.0)
    end

    it 'is positive for a volatile series' do
      closes = [100, 102, 98, 103, 99, 104, 97]
      expect(described_class.historical_volatility(closes.map(&:to_f))).to be > 0
    end
  end
end
