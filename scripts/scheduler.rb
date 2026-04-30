#!/usr/bin/env ruby
# scripts/scheduler.rb
#
# Tiered cache refresh dispatcher. Designed to be called from cron / launchd at
# different cadences for different data classes:
#
#   Tier            Cadence (suggested)         What it refreshes
#   ──────────────  ──────────────────────────  ─────────────────────────────────
#   quotes          every 15 min, market hours  Live prices for REGIONS + watchlist + portfolio
#   fundamentals    daily 03:00 local           FMP key metrics, ratios, DCF, earnings
#   analyst         weekly Sunday 04:00 local   Finnhub analyst consensus
#   macro           daily 04:30 local           FRED, Stooq, news
#   alerts          every 15 min, market hours  Evaluate active price alerts
#   all             ad-hoc                      everything except alerts
#
# Usage:
#   bundle exec ruby scripts/scheduler.rb --tier=quotes
#   bundle exec ruby scripts/scheduler.rb --tier=fundamentals
#   make scheduler TIER=macro
#
# Cron example (US Eastern):
#   */15 9-16 * * 1-5  cd /path/to/t-money-terminal && bundle exec ruby scripts/scheduler.rb --tier=quotes >> data/scheduler.log 2>&1
#   */15 9-16 * * 1-5  cd /path/to/t-money-terminal && bundle exec ruby scripts/scheduler.rb --tier=alerts >> data/scheduler.log 2>&1
#   0 3   * * *        cd /path/to/t-money-terminal && bundle exec ruby scripts/scheduler.rb --tier=fundamentals >> data/scheduler.log 2>&1
#   30 4  * * *        cd /path/to/t-money-terminal && bundle exec ruby scripts/scheduler.rb --tier=macro       >> data/scheduler.log 2>&1
#   0 4   * * 0        cd /path/to/t-money-terminal && bundle exec ruby scripts/scheduler.rb --tier=analyst     >> data/scheduler.log 2>&1
#
# launchd example (macOS): see scripts/launchd/com.tmoney.scheduler.quotes.plist

$LOAD_PATH.unshift File.expand_path('../app', __dir__)

require 'dotenv'
Dotenv.load(
  File.expand_path('../.env',         __dir__),
  File.expand_path('../.credentials', __dir__)
)

require 'optparse'
require 'date'
require 'time'

require 'market_data_service'
require 'providers'
require 'symbol_index'
require 'watchlist_store'
require 'portfolio_store'
require 'alerts_store'
require 'refresh_universe'

VALID_TIERS = %w[quotes fundamentals analyst macro alerts all].freeze

opts = { tier: nil, force: false }
OptionParser.new do |o|
  o.banner = 'Usage: scheduler.rb --tier=<quotes|fundamentals|analyst|macro|alerts|all> [--force]'
  o.on('--tier=TIER', VALID_TIERS, "Which tier to refresh (#{VALID_TIERS.join('|')})") { |v| opts[:tier] = v }
  o.on('--force',     'Run even outside market hours where applicable')              { opts[:force] = true }
end.parse!

unless opts[:tier]
  warn 'scheduler.rb: --tier is required'
  exit 64
end

# Single source of truth for the symbol set lives in RefreshUniverse.
# Scheduler historically iterated `SymbolIndex.symbols + portfolio +
# watchlist`, which transitively pulled in extensions + curated. Preserve
# that behaviour here so an existing cron job's per-tick budget doesn't
# silently shrink.
def universe
  RefreshUniverse.symbols(include_extensions: true, include_curated: true)
end

# US equities cash session: 09:30–16:00 ET, Mon–Fri. Approximate via UTC offset
# fixed to -05:00 (EST) — close enough for "skip on weekends / overnight" use.
# `--force` overrides.
def market_hours?
  t = Time.now.utc - (5 * 3600) # naive ET conversion
  return false if t.saturday? || t.sunday?
  hour_minute = t.hour * 60 + t.min
  hour_minute.between?(9 * 60 + 30, 16 * 60)
end

def log(msg)
  puts "[#{Time.now.iso8601}] #{msg}"
end

def run_quotes(force:)
  unless force || market_hours?
    log 'quotes: market closed, skipping (use --force to override).'
    return
  end
  syms = universe
  log "quotes: refreshing #{syms.size} symbol(s)"
  syms.each do |sym|
    MarketDataService.refresh_symbol_live_cache!(sym)
    MarketDataService.quote(sym)
    sleep 0.5 # gentle pacing to avoid bursting any single provider
  end
  log 'quotes: done'
end

def run_fundamentals(*)
  return log('fundamentals: FMP_API_KEY not set, skipping') unless ENV['FMP_API_KEY'] && !ENV['FMP_API_KEY'].empty?

  syms = (PortfolioStore.symbols + WatchlistStore.read + MarketDataService::REGIONS[:us]).map(&:upcase).uniq
  log "fundamentals: refreshing #{syms.size} symbol(s)"
  syms.each do |sym|
    next if MarketDataService::SYMBOL_TYPES[sym] == 'ETF' # ETFs have no fundamentals
    Providers::FmpService.key_metrics(sym, limit: 1)
    Providers::FmpService.ratios(sym, limit: 1)
    Providers::FmpService.dcf(sym)
    sleep 1
  end
  Providers::FmpService.earnings_calendar(days_ahead: 14) # one shared call
  log 'fundamentals: done'
end

def run_analyst(*)
  return log('analyst: FINNHUB_API_KEY not set, skipping') unless ENV['FINNHUB_API_KEY'] && !ENV['FINNHUB_API_KEY'].empty?

  syms = universe
  log "analyst: refreshing #{syms.size} symbol(s)"
  syms.each do |sym|
    MarketDataService.analyst_recommendations(sym)
    sleep 2 # Finnhub is 60/min — 2s pacing is conservative
  end
  log 'analyst: done'
end

def run_macro(*)
  log 'macro: FRED snapshot'
  Providers::FredService.macro_snapshot
  log 'macro: international indices (Stooq)'
  %i[sp500 nasdaq dow nikkei hang_seng dax ftse cac].each { |k| Providers::StooqService.index(k) }
  if ENV['FINNHUB_API_KEY'] && !ENV['FINNHUB_API_KEY'].empty?
    log 'macro: news for portfolio + watchlist'
    syms = (PortfolioStore.symbols + WatchlistStore.read).uniq
    syms.each do |sym|
      Providers::NewsService.company_news(sym, days: 7, limit: 8)
      sleep 1
    end
  end
  log 'macro: done'
end

def run_alerts(*)
  unless market_hours?
    log 'alerts: market closed, skipping (use --force to override).'
    return
  end
  log 'alerts: invoking check_alerts.rb'
  system('bundle', 'exec', 'ruby', File.expand_path('check_alerts.rb', __dir__)) || log('alerts: check_alerts.rb returned non-zero')
end

case opts[:tier]
when 'quotes'        then run_quotes(force: opts[:force])
when 'fundamentals'  then run_fundamentals
when 'analyst'       then run_analyst
when 'macro'         then run_macro
when 'alerts'        then run_alerts
when 'all'
  run_quotes(force: true)
  run_fundamentals
  run_analyst
  run_macro
end
