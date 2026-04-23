ENV['RACK_ENV'] = 'test'

require 'rspec'
require 'json'
require_relative '../app/providers'

# Stub HttpClient so specs never hit the network.
module Providers::HttpClient
  class << self
    attr_accessor :stubbed_json, :stubbed_text
  end

  def self.get_json(_url, **_opts)
    stubbed_json || [200, {}, '{}']
  end

  def self.get_text(_url, **_opts)
    stubbed_text || [200, '']
  end
end

RSpec.describe Providers::CacheStore do
  it 'returns nil for missing keys' do
    expect(described_class.read('test_ns', 'missing', ttl: 60)).to be_nil
  end

  it 'is a no-op write in test env' do
    # RACK_ENV=test means writes are skipped — still returns the value.
    val = described_class.write('test_ns', 'skipped', { a: 1 })
    expect(val).to eq(a: 1)
    expect(described_class.read('test_ns', 'skipped', ttl: 60)).to be_nil
  end
end

RSpec.describe Providers::FmpService do
  before do
    ENV['FMP_API_KEY'] = 'test-key'
    Providers::HttpClient.stubbed_json = nil
  end

  it 'returns nil when FMP_API_KEY is absent' do
    ENV.delete('FMP_API_KEY')
    expect(described_class.income_statement('AAPL')).to be_nil
  end

  it 'parses income statement response' do
    Providers::HttpClient.stubbed_json = [200, [{ 'date' => '2025-12-31', 'revenue' => 1000 }], '[]']
    result = described_class.income_statement('AAPL', limit: 1)
    expect(result).to be_an(Array)
    expect(result.first[:revenue]).to eq(1000)
  end

  it 'returns nil on HTTP 429' do
    Providers::HttpClient.stubbed_json = [429, { 'Error Message' => 'limit' }, '']
    expect(described_class.ratios('AAPL')).to be_nil
  end

  it 'returns nil on API-level error payload' do
    Providers::HttpClient.stubbed_json = [200, { 'Error Message' => 'bad key' }, '']
    expect(described_class.key_metrics('AAPL')).to be_nil
  end
end

RSpec.describe Providers::PolygonService do
  before do
    ENV['POLYGON_API_KEY'] = 'test-key'
    Providers::HttpClient.stubbed_json = nil
  end

  it 'returns nil when POLYGON_API_KEY is absent' do
    ENV.delete('POLYGON_API_KEY')
    expect(described_class.contracts('AAPL')).to be_nil
  end

  it 'extracts results array from contracts response' do
    Providers::HttpClient.stubbed_json = [200, { 'results' => [{ 'ticker' => 'O:AAPL' }] }, '']
    expect(described_class.contracts('AAPL')).to eq([{ 'ticker' => 'O:AAPL' }])
  end

  it 'normalizes aggregates to date/OHLCV hashes' do
    bar = { 't' => 1_700_000_000_000, 'o' => 1, 'h' => 2, 'l' => 0.5, 'c' => 1.5, 'v' => 100 }
    Providers::HttpClient.stubbed_json = [200, { 'results' => [bar] }, '']
    result = described_class.daily_aggregates('AAPL', from: '2023-01-01', to: '2023-12-31')
    expect(result.first).to include('open' => 1, 'close' => 1.5, 'volume' => 100)
    expect(result.first['date']).to match(/\d{4}-\d{2}-\d{2}/)
  end

  it 'returns nil on Polygon ERROR status payload' do
    Providers::HttpClient.stubbed_json = [200, { 'status' => 'ERROR', 'error' => 'x' }, '']
    expect(described_class.contracts('AAPL')).to be_nil
  end
end

RSpec.describe Providers::FredService do
  before do
    ENV['FRED_API_KEY'] = 'test-key'
    Providers::HttpClient.stubbed_json = nil
  end

  it 'returns nil when FRED_API_KEY is absent' do
    ENV.delete('FRED_API_KEY')
    expect(described_class.observations(:treasury_10yr)).to be_nil
  end

  it 'resolves series symbol to FRED id and parses observations' do
    body = { 'observations' => [{ 'date' => '2026-04-22', 'value' => '4.21' }] }
    Providers::HttpClient.stubbed_json = [200, body, '']
    rows = described_class.observations(:treasury_3mo, limit: 1)
    expect(rows).to eq([{ date: '2026-04-22', value: 4.21 }])
  end

  it 'converts risk-free rate percent → decimal' do
    body = { 'observations' => [{ 'date' => '2026-04-22', 'value' => '4.5' }] }
    Providers::HttpClient.stubbed_json = [200, body, '']
    expect(described_class.risk_free_rate(term: :treasury_3mo)).to be_within(1e-9).of(0.045)
  end

  it 'drops FRED missing-value sentinels (".")' do
    body = { 'observations' => [{ 'date' => '2026-04-22', 'value' => '.' }] }
    Providers::HttpClient.stubbed_json = [200, body, '']
    expect(described_class.observations(:treasury_3mo, limit: 1)).to eq([])
  end
end

RSpec.describe Providers::NewsService do
  before do
    ENV['FINNHUB_API_KEY'] = 'test-key'
    ENV.delete('NEWSAPI_KEY')
    Providers::HttpClient.stubbed_json = nil
  end

  it 'returns nil when no providers are configured' do
    ENV.delete('FINNHUB_API_KEY')
    expect(described_class.company_news('AAPL')).to be_nil
  end

  it 'normalizes Finnhub articles to the shared shape' do
    body = [{
      'headline' => 'Apple beats earnings',
      'summary'  => 'Revenue up.',
      'url'      => 'https://example.com/a',
      'source'   => 'Example',
      'datetime' => 1_700_000_000,
      'image'    => 'https://example.com/i.png'
    }]
    Providers::HttpClient.stubbed_json = [200, body, '']
    articles = described_class.company_news('AAPL')
    expect(articles.first[:headline]).to eq('Apple beats earnings')
    expect(articles.first[:url]).to eq('https://example.com/a')
    expect(articles.first[:datetime]).to match(/\A\d{4}-\d{2}-\d{2}T/)
  end
end

RSpec.describe Providers::StooqService do
  before { Providers::HttpClient.stubbed_text = nil }

  it 'parses Stooq CSV into an OHLCV hash' do
    csv = "Symbol,Date,Time,Open,High,Low,Close,Volume\n" \
          "^NKX,2026-04-23,08:30:00,37500.00,37820.00,37480.00,37780.00,0\n"
    Providers::HttpClient.stubbed_text = [200, csv]
    row = described_class.index(:nikkei)
    expect(row[:close]).to eq(37780.0)
    expect(row[:date]).to eq('2026-04-23')
    expect(row[:name]).to eq('nikkei')
  end

  it 'returns nil for unknown index name' do
    expect(described_class.index(:unknown_idx)).to be_nil
  end

  it 'returns nil when Stooq reports no data (N/D sentinel)' do
    csv = "Symbol,Date,Time,Open,High,Low,Close,Volume\nN/D,N/D,N/D,N/D,N/D,N/D,N/D,N/D\n"
    Providers::HttpClient.stubbed_text = [200, csv]
    expect(described_class.index(:nikkei)).to be_nil
  end
end

RSpec.describe Providers::EdgarService do
  before { Providers::HttpClient.stubbed_json = nil }

  it 'parses submissions index into filing rows' do
    body = {
      'filings' => {
        'recent' => {
          'form'            => ['10-Q', '8-K'],
          'filingDate'      => ['2026-04-01', '2026-03-10'],
          'accessionNumber' => ['0000320193-26-000001', '0000320193-26-000002'],
          'primaryDocument' => ['aapl10q.htm', 'aapl8k.htm']
        }
      }
    }
    Providers::HttpClient.stubbed_json = [200, body, '']
    rows = described_class.recent_filings('320193', limit: 5)
    expect(rows.length).to eq(2)
    expect(rows.first[:form]).to eq('10-Q')
    expect(rows.first[:url]).to include('aapl10q.htm')
  end
end
