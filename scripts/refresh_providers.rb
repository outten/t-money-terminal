#!/usr/bin/env ruby
# scripts/refresh_providers.rb
#
# Warm the provider-module caches (FMP, FRED, News, Stooq, Polygon) that
# back the new dashboard and analysis panels. Mirrors the style of
# scripts/refresh_cache.rb and respects each provider's rate limits.
#
# Usage:
#   bundle exec ruby scripts/refresh_providers.rb            # all equity symbols
#   bundle exec ruby scripts/refresh_providers.rb AAPL MSFT  # subset
#   bundle exec ruby scripts/refresh_providers.rb --options  # include Polygon options
#   make refresh-all                                          # refresh_cache.rb + this
#
# Rate limits honored:
#   FMP      – 250 req/day    → 0.5 s spacing (polite; cap is daily, not minute)
#   Polygon  – 5  req/min     → 13 s between calls (skipped unless --options)
#   FRED     – effectively unlimited → 0.1 s spacing
#   Finnhub  – 60 req/min     → 2  s between calls (news)
#   Stooq    – no auth        → 1  s between calls (be polite)

$LOAD_PATH.unshift File.expand_path('../app', __dir__)

require 'dotenv'
Dotenv.load(
  File.expand_path('../.env',         __dir__),
  File.expand_path('../.credentials', __dir__)
)
require 'market_data_service'
require 'providers'

# ── Helpers ─────────────────────────────────────────────────────────────────

def say(msg, level: :info)
  prefix = case level
           when :ok      then "\e[32m  ✓\e[0m"
           when :warn    then "\e[33m  ⚠\e[0m"
           when :error   then "\e[31m  ✗\e[0m"
           when :skip    then "\e[90m  –\e[0m"
           when :section then "\e[1;34m▶\e[0m"
           else               '  ·'
           end
  puts "#{prefix} #{msg}"
end

def check_key(name)
  val = ENV[name]
  if val && !val.empty?
    say "#{name} present (#{val[0, 4]}…)", level: :ok
    true
  else
    say "#{name} not set — related phases will be skipped", level: :warn
    false
  end
end

# Force a refresh of a cached provider entry by deleting the on-disk file,
# then calling the provider method so it re-fetches and re-caches.
def force_refresh(namespace, key)
  Providers::CacheStore.delete(namespace, key)
end

# ── Configuration ────────────────────────────────────────────────────────────

include_options = ARGV.delete('--options') ? true : false
all_symbols     = MarketDataService::REGIONS.values.flatten.uniq
etf_symbols     = MarketDataService::SYMBOL_TYPES.keys

target_symbols = if ARGV.any?
                   unknown = ARGV.map(&:upcase) - all_symbols
                   unless unknown.empty?
                     say "Unknown symbol(s): #{unknown.join(', ')} — ignored", level: :warn
                   end
                   ARGV.map(&:upcase) & all_symbols
                 else
                   all_symbols
                 end

if target_symbols.empty?
  say 'No valid symbols to refresh. Exiting.', level: :error
  exit 1
end

equity_symbols = target_symbols - etf_symbols
stooq_indices  = %i[nikkei dax ftse cac hang_seng]

# ── Preamble ─────────────────────────────────────────────────────────────────

puts
puts "\e[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m"
puts "\e[1m  T Money Terminal — Provider Cache Refresh\e[0m"
puts "\e[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m"
puts "  Started : #{Time.now.strftime('%Y-%m-%d %H:%M:%S %Z')}"
puts "  Symbols : #{target_symbols.join(', ')}"
puts "  Equity  : #{equity_symbols.join(', ')} (FMP targets)"
puts "  ETFs    : #{(target_symbols & etf_symbols).join(', ')} (skipped for FMP)"
puts "  Options : #{include_options ? 'INCLUDED (--options)' : 'SKIPPED (pass --options to enable)'}"
puts

say 'Checking API keys…', level: :section
fmp_ok     = check_key('FMP_API_KEY')
fred_ok    = check_key('FRED_API_KEY')
finnhub_ok = check_key('FINNHUB_API_KEY')
polygon_ok = check_key('POLYGON_API_KEY')
newsapi_ok = ENV['NEWSAPI_KEY'] && !ENV['NEWSAPI_KEY'].empty?
say "NEWSAPI_KEY #{newsapi_ok ? 'present (fallback available)' : 'absent (Finnhub-only news)'}",
    level: newsapi_ok ? :ok : :skip
puts

# ── Phase 1: FRED macro snapshot ────────────────────────────────────────────

say 'Phase 1 — FRED macro snapshot', level: :section
if fred_ok
  # Bust the per-series cache files so observations() actually re-fetches.
  %i[fed_funds treasury_3mo treasury_2yr treasury_10yr treasury_30yr cpi unemployment vix].each do |key|
    series_id = Providers::FredService::SERIES[key]
    force_refresh('fred', "obs_#{series_id}_1")
  end

  snapshot = Providers::FredService.macro_snapshot
  snapshot.each do |key, row|
    if row
      say "#{key}: #{row[:value]} (#{row[:date]})", level: :ok
    else
      say "#{key}: no data", level: :warn
    end
  end
else
  say 'Skipped — FRED_API_KEY missing', level: :skip
end
puts

# ── Phase 2: Stooq international indices ────────────────────────────────────

say 'Phase 2 — Stooq international indices', level: :section
stooq_indices.each do |idx|
  force_refresh('stooq', idx.to_s)
  row = Providers::StooqService.index(idx)
  if row
    say "#{idx}: close=#{row[:close]} date=#{row[:date]}", level: :ok
  else
    say "#{idx}: no data returned", level: :warn
  end
end
puts

# ── Phase 3: FMP fundamentals (equities only) ───────────────────────────────

say 'Phase 3 — FMP fundamentals, ratios, DCF, earnings', level: :section
if !fmp_ok
  say 'Skipped — FMP_API_KEY missing', level: :skip
elsif equity_symbols.empty?
  say 'Skipped — no non-ETF symbols in the target list', level: :skip
else
  say "Fetching 7 endpoints per symbol (~#{equity_symbols.length * 7} FMP calls total; daily cap 250)"
  equity_symbols.each do |sym|
    say "#{sym}: warming FMP caches…"

    # Bust all FMP cache files for this symbol so subsequent calls re-fetch.
    %W[
      income-statement_#{sym}_1
      balance-sheet-statement_#{sym}_1
      cash-flow-statement_#{sym}_1
      key_metrics_#{sym}_1
      ratios_#{sym}_1
      dcf_#{sym}
      earnings_#{sym}
    ].each { |k| force_refresh('fmp', k) }

    # Bust today's earnings calendar once per refresh run so it re-fetches.
    # (Subsequent symbols in this loop will hit the shared 6 h cache.)
    if sym == equity_symbols.first
      Dir.glob(File.join(Providers::CacheStore::CACHE_ROOT, 'fmp', 'earnings-calendar_*.json'))
         .each { |f| File.delete(f) rescue nil }
    end

    begin
      is   = Providers::FmpService.income_statement(sym, limit: 1)
      bs   = Providers::FmpService.balance_sheet(sym, limit: 1)
      cf   = Providers::FmpService.cash_flow(sym, limit: 1)
      km   = Providers::FmpService.key_metrics(sym, limit: 1)
      r    = Providers::FmpService.ratios(sym, limit: 1)
      dcf  = Providers::FmpService.dcf(sym)
      er   = Providers::FmpService.next_earnings(sym)
      ok   = [is, bs, cf, km, r, dcf].count { |x| x && (x.is_a?(Array) ? !x.empty? : !x.empty?) }
      say "#{sym}: #{ok}/6 core endpoints + earnings=#{er ? er[:date] : 'none'}",
          level: ok >= 4 ? :ok : :warn
    rescue StandardError => e
      say "#{sym}: FMP error — #{e.message}", level: :error
    end
  end
end
puts

# ── Phase 4: Company news (Finnhub primary, NewsAPI fallback) ───────────────

say 'Phase 4 — Company news', level: :section
if !finnhub_ok && !newsapi_ok
  say 'Skipped — neither FINNHUB_API_KEY nor NEWSAPI_KEY is set', level: :skip
else
  target_symbols.each do |sym|
    force_refresh('news', "#{sym}_7")
    articles = Providers::NewsService.company_news(sym, days: 7, limit: 8)
    if articles && !articles.empty?
      say "#{sym}: #{articles.length} articles (latest: #{articles.first[:headline][0, 60]}…)", level: :ok
    else
      say "#{sym}: no articles returned", level: :warn
    end
  end
end
puts

# ── Phase 5: Polygon options (gated, slow) ──────────────────────────────────

if include_options
  say 'Phase 5 — Polygon options contracts (--options)', level: :section
  if !polygon_ok
    say 'Skipped — POLYGON_API_KEY missing', level: :skip
  elsif equity_symbols.empty?
    say 'Skipped — no equity symbols in target list', level: :skip
  else
    say "Rate limit: 13 s between calls (5 req/min free tier)"
    equity_symbols.each do |sym|
      force_refresh('polygon', "contracts_#{sym}_all_250")
      contracts = Providers::PolygonService.contracts(sym, limit: 250)
      if contracts && !contracts.empty?
        say "#{sym}: #{contracts.length} option contracts cached", level: :ok
      else
        say "#{sym}: no contracts returned", level: :warn
      end
    end
  end
  puts
else
  say 'Phase 5 — Polygon options: SKIPPED (pass --options to enable)', level: :skip
  puts
end

# ── Summary ──────────────────────────────────────────────────────────────────

puts "\e[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m"
say "Provider cache refresh complete", level: :ok
puts "  Finished : #{Time.now.strftime('%Y-%m-%d %H:%M:%S %Z')}"

provider_dirs = %w[fmp fred news stooq polygon edgar]
cache_root    = File.expand_path('../data/cache', __dir__)
provider_dirs.each do |d|
  dir = File.join(cache_root, d)
  next unless Dir.exist?(dir)
  files = Dir.glob(File.join(dir, '*.json'))
  next if files.empty?
  size_kb = files.sum { |f| File.size(f) } / 1024.0
  puts "  #{d.ljust(8)}: #{files.length} entries, #{size_kb.round(1)} KB"
end

puts "\e[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m"
puts
