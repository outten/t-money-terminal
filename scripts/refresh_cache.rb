#!/usr/bin/env ruby
# scripts/refresh_cache.rb
#
# Manually refresh all cached market data, respecting API rate limits.
# This script fetches fresh data from each provider and writes it to the
# persistent disk cache so the web app serves current data immediately.
#
# Usage:
#   bundle exec ruby scripts/refresh_cache.rb       # full refresh
#   bundle exec ruby scripts/refresh_cache.rb AAPL  # single symbol
#   make refresh-cache
#
# Rate limits honored:
#   Alpha Vantage  – 5 req/min, 25 req/day (free tier) → 15 s between AV calls
#   Finnhub        – 60 req/min (free tier)             →  2 s between calls
#   Yahoo Finance  – aggressive IP-based throttling     → crumb auth + retry

$LOAD_PATH.unshift File.expand_path('../app', __dir__)

require 'dotenv'
Dotenv.load(
  File.expand_path('../.env',         __dir__),
  File.expand_path('../.credentials', __dir__)
)
require 'market_data_service'

# ── Helpers ─────────────────────────────────────────────────────────────────

def say(msg, level: :info)
  prefix = case level
           when :ok      then "\e[32m  ✓\e[0m"
           when :warn    then "\e[33m  ⚠\e[0m"
           when :error   then "\e[31m  ✗\e[0m"
           when :skip    then "\e[90m  –\e[0m"
           when :section then "\e[1;34m▶\e[0m"
           else               "  ·"
           end
  puts "#{prefix} #{msg}"
end

def pause(seconds, reason)
  print "  ⏳ Waiting #{seconds}s (#{reason})"
  seconds.times do
    sleep 1
    print '.'
  end
  puts ' done'
end

def check_key(name)
  val = ENV[name]
  if val && !val.empty?
    say "#{name} present (#{val[0, 4]}…)", level: :ok
    true
  else
    say "#{name} not set — calls requiring it will be skipped", level: :warn
    false
  end
end

# ── Configuration ────────────────────────────────────────────────────────────

AV_SLEEP      = 15  # seconds between Alpha Vantage calls (≤5/min)
FINNHUB_SLEEP =  2  # seconds between Finnhub calls      (≤60/min)
HISTORICAL_PERIODS = %w[1d 1m 3m ytd 1y 5y].freeze

all_symbols = MarketDataService::REGIONS.values.flatten.uniq
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

# ── Preamble ─────────────────────────────────────────────────────────────────

puts
puts "\e[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m"
puts "\e[1m  T Money Terminal — Cache Refresh\e[0m"
puts "\e[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m"
puts "  Started : #{Time.now.strftime('%Y-%m-%d %H:%M:%S %Z')}"
puts "  Symbols : #{target_symbols.join(', ')}"
puts "  Cache   : #{MarketDataService::CACHE_FILE}"
puts

say 'Checking API keys…', level: :section
av_ok      = check_key('ALPHA_VANTAGE_API_KEY')
finnhub_ok = check_key('FINNHUB_API_KEY')
puts

# ── Phase 1: Quotes ──────────────────────────────────────────────────────────

say 'Phase 1 — Quotes', level: :section
say "Strategy: Alpha Vantage → Finnhub → Yahoo Finance per symbol"
say "Rate limit: #{AV_SLEEP}s pause after each Alpha Vantage call"
puts

target_symbols.each_with_index do |symbol, i|
  say "#{symbol}: fetching quote…"

  # Bust only the quote key so the service actually hits the network
  MarketDataService.bust_cache_for_symbol!(symbol)

  result = MarketDataService.quote(symbol)
  price  = result['05. price'] || result[:price]

  if price && price != 'N/A'
    say "#{symbol}: price = #{price}", level: :ok
  else
    say "#{symbol}: got mock/fallback data only", level: :warn
  end

  # AV is the first provider tried; pause after every call to stay under 5/min
  if av_ok && i < target_symbols.length - 1
    pause(AV_SLEEP, "Alpha Vantage rate limit (5 req/min)")
  end
end
puts

# ── Phase 2: Analyst Recommendations ────────────────────────────────────────

say 'Phase 2 — Analyst Recommendations (Finnhub)', level: :section
unless finnhub_ok
  say 'FINNHUB_API_KEY not set — skipping analyst refresh', level: :skip
  puts
else
  say "Rate limit: #{FINNHUB_SLEEP}s pause between calls"
  puts

  target_symbols.each_with_index do |symbol, i|
    say "#{symbol}: fetching analyst consensus…"
    result = MarketDataService.analyst_recommendations(symbol)

    if result
      total = result.values_at(:strong_buy, :buy, :hold, :sell, :strong_sell).compact.sum
      say "#{symbol}: #{total} analyst ratings (period: #{result[:period]})", level: :ok
    else
      say "#{symbol}: no analyst data returned", level: :warn
    end

    pause(FINNHUB_SLEEP, "Finnhub rate limit") if i < target_symbols.length - 1
  end
  puts
end

# ── Phase 3: Company Profiles ────────────────────────────────────────────────

say 'Phase 3 — Company Profiles (Finnhub / hardcoded ETFs)', level: :section
unless finnhub_ok
  say 'FINNHUB_API_KEY not set — ETF profiles will still be cached from hardcoded data', level: :warn
  puts
else
  say "Rate limit: #{FINNHUB_SLEEP}s pause between Finnhub calls"
  puts
end

target_symbols.each_with_index do |symbol, i|
  say "#{symbol}: fetching company profile…"
  result = MarketDataService.company_profile(symbol)

  if result
    source = result[:source] || 'hardcoded ETF profile'
    say "#{symbol}: #{result[:name]} (#{source})", level: :ok
  else
    say "#{symbol}: no profile data returned", level: :warn
  end

  if finnhub_ok && !MarketDataService::ETF_PROFILES.key?(symbol) && i < target_symbols.length - 1
    pause(FINNHUB_SLEEP, "Finnhub rate limit")
  end
end
puts

# ── Phase 4: Historical Price Data ───────────────────────────────────────────

say 'Phase 4 — Historical Price Data', level: :section
say "Strategy: Yahoo Finance (crumb auth) → Alpha Vantage TIME_SERIES_WEEKLY"
say "AV efficiency: one API call per symbol populates all 6 period caches"
say "Rate limit: #{AV_SLEEP}s pause after each AV call"
puts

target_symbols.each_with_index do |symbol, i|
  say "#{symbol}: fetching historical data for all periods (#{HISTORICAL_PERIODS.join(', ')})…"

  # First try Yahoo Finance for 1y (most likely to be populated)
  yahoo_result = MarketDataService.historical(symbol, '1y')
  if yahoo_result && !yahoo_result.empty?
    say "#{symbol}: Yahoo returned #{yahoo_result.length} data points for 1y", level: :ok
    # Fetch remaining periods from Yahoo as well
    (HISTORICAL_PERIODS - ['1y']).each do |period|
      r = MarketDataService.historical(symbol, period)
      if r && !r.empty?
        say "  #{period.upcase}: #{r.length} points", level: :ok
      else
        say "  #{period.upcase}: no data from Yahoo", level: :skip
      end
    end
  else
    say "#{symbol}: Yahoo returned no data — trying Alpha Vantage (1 call → all periods)…", level: :warn

    if av_ok
      results = MarketDataService.prefetch_all_historical(symbol)
      if results[:rate_limited]
        say "#{symbol}: Alpha Vantage rate limit hit (daily quota may be exhausted)", level: :error
      elsif results.empty?
        say "#{symbol}: Alpha Vantage returned no data", level: :error
      else
        fetched = results.count { |_, v| v && !v.empty? }
        say "#{symbol}: AV populated #{fetched}/#{HISTORICAL_PERIODS.length} period caches", level: fetched > 0 ? :ok : :warn
        HISTORICAL_PERIODS.each do |period|
          pts = results[period]
          if pts && !pts.empty?
            say "  #{period.upcase}: #{pts.length} points", level: :ok
          else
            say "  #{period.upcase}: no data", level: :skip
          end
        end
      end

      pause(AV_SLEEP, "Alpha Vantage rate limit") if i < target_symbols.length - 1
    else
      say "#{symbol}: no historical data — no API keys available", level: :error
    end
  end
  puts
end

# ── Summary ──────────────────────────────────────────────────────────────────

puts "\e[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m"
say "Cache refresh complete", level: :ok
puts "  Finished : #{Time.now.strftime('%Y-%m-%d %H:%M:%S %Z')}"
puts "  Cache    : #{MarketDataService::CACHE_FILE}"

if File.exist?(MarketDataService::CACHE_FILE)
  size_kb = (File.size(MarketDataService::CACHE_FILE) / 1024.0).round(1)
  puts "  Size     : #{size_kb} KB"
end

puts "\e[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m"
puts
