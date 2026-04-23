# Agent Instructions — T Money Terminal

## Setup & Credentials

Credentials live in `.credentials` (NOT `.env`). The app uses `Dotenv.load` to load from both files, but `.credentials` is the primary source.

```ruby
# app/main.rb and app/market_data_service.rb
Dotenv.load(File.expand_path('../../.credentials', __FILE__))
```

**API Keys Required:**
- `TIINGO_API_KEY` — primary historical data source
- `ALPHA_VANTAGE_API_KEY` — quotes fallback (5 req/min, 25 req/day free tier)
- `FINNHUB_API_KEY` — analyst recommendations + company profiles (60 req/min)

Never commit `.credentials` or `.env` — both are in `.gitignore`.

## Development Commands

```bash
make install          # bundle install
make run              # production mode: ruby app/main.rb → :4567
make dev              # dev mode with auto-reload: rerun 'ruby app/main.rb'
make test             # run full RSpec suite
make refresh-cache    # force-refresh all market data (respects rate limits)
make refresh-symbol SYMBOL=AAPL  # refresh single symbol
make cache-status     # show cache age/staleness
```

**Critical:** Use `make dev` for local development (auto-reloads on file changes). Use `make run` for production-like testing.

## Caching Architecture

Market data is cached on **disk** at `data/cache/` with hierarchical structure and 1-hour TTL (`MarketDataService::CACHE_TTL = 3600`).

**Cache structure:**
```
data/cache/
├── quotes/           # Real-time price quotes (SYMBOL.json)
├── historical/       # Historical price data (SYMBOL_PERIOD.json)
├── analyst/          # Analyst recommendations (SYMBOL.json)
└── profiles/         # Company profiles (SYMBOL.json)
```

**Cache busting:**
- UI: Click **REFRESH** button on any page (dashboard, region, analysis)
- CLI: `make refresh-cache` — runs `scripts/refresh_cache.rb`, which fetches all symbols sequentially with rate-limit pauses (15s between AV calls, 2s between Finnhub calls)
- API: `MarketDataService.bust_cache_for_symbol!(symbol)` — bust a single symbol's cache (in-memory + disk files)

**Rate limit handling:**
- Alpha Vantage: 15s pause between calls (5 req/min limit)
- Finnhub: 2s pause between calls (60 req/min limit)
- Yahoo Finance: primary historical data source (aggressive IP throttling, uses crumb auth + retry)

**Data flow:**
1. Quotes: Tiingo → Alpha Vantage → Finnhub → Yahoo Finance (waterfall)
2. Historical: Yahoo Finance → Finnhub candles → Tiingo → Alpha Vantage TIME_SERIES_WEEKLY
3. Analyst: Finnhub only
4. Profiles: Finnhub for stocks; hardcoded `ETF_PROFILES` for SPY/QQQ/EWJ/VGK

**Legacy cache migration:**
- Old location: `.cache/market_cache.json` (monolithic JSON)
- New location: `data/cache/` (hierarchical, per-entry files)
- Legacy tmp location: `tmp/market_cache.json` (deprecated)
- System auto-migrates on first load

## Project Structure

```
app/
  main.rb                  # Sinatra routes (TMoneyTerminal class)
  market_data_service.rb   # 946 lines — cache, API calls, mock fallback
  recommendation_service.rb # Buy/Sell/Hold signal logic
views/
  *.erb                    # ERB templates with shared layout
public/
  style.css, app.js        # Apple-inspired design, Chart.js charts
scripts/
  refresh_cache.rb         # Manual cache refresh (honors rate limits)
  cache_status.rb          # Display cache age/staleness
spec/
  app_spec.rb              # Route smoke tests (Rack::Test)
  services_spec.rb         # Service unit tests
```

**Key constants in `MarketDataService`:**
- `REGIONS` — hash of `:us`, `:japan`, `:europe` arrays
- `SYMBOL_TYPES` — hardcoded ETF type override (SPY/QQQ/EWJ/VGK)
- `ETF_PROFILES` — hardcoded metadata for 4 ETFs
- `MOCK_PRICES` — fallback data when API keys are missing

## Testing

```bash
make test  # runs all RSpec specs
```

- `spec/app_spec.rb` — route tests using `Rack::Test::Methods`
- `spec/services_spec.rb` — unit tests for market data and recommendation services
- Tests run with `ENV['RACK_ENV'] = 'test'`

**No CI/pre-commit hooks configured.**

## Common Gotchas

1. **Credentials confusion:** The app loads both `.credentials` and `.env` via Dotenv, but `.credentials` is the primary file. Don't assume keys are in `.env`.

2. **Cache location changed:** Legacy cache was `tmp/market_cache.json`, then `.cache/market_cache.json`, now it's `data/cache/` with hierarchical structure. System auto-migrates from old locations on first load.

3. **ETF vs Stock logic:** ETFs (SPY/QQQ/EWJ/VGK) use hardcoded profiles from `ETF_PROFILES` constant. Stocks fetch from Finnhub. Check `SYMBOL_TYPES` before assuming API behavior.

4. **Rate limits are strict:** `scripts/refresh_cache.rb` enforces 15s pauses for Alpha Vantage. Do not parallelize or batch AV calls without respecting this limit (5 req/min, 25 req/day free tier).

5. **Historical data period keys:** Yahoo Finance uses `YAHOO_RANGE_MAP` keys (`'1d'`, `'1m'`, `'3m'`, `'ytd'`, `'1y'`, `'5y'`). Cache keys are namespaced by period, e.g., `"historical:AAPL:1m"`.

6. **Recommendation logic:** `RecommendationService` issues BUY/SELL/HOLD based on simple price change thresholds (>+1% = BUY, <-1% = SELL). To extend with SMA/RSI, use Alpha Vantage Technical Indicator endpoints (not yet implemented).

## Documentation Files

- `README.md` — user-facing overview
- `DEVELOPER.md` — project structure and API docs
- `Instructions.md` — setup guide (API keys, running, interpreting signals)
- `CREDENTIALS.md` — API key setup instructions
- `SPEC.md`, `ANALYSIS.md` — design specs and data source citations

## Framework Details

- **Web:** Sinatra (Ruby DSL for HTTP)
- **Templates:** ERB (views/*.erb with shared layout)
- **Server:** Puma (via Gemfile)
- **Dev reload:** Rerun gem (watches files, restarts on change)
- **Testing:** RSpec + Rack::Test
- **Env loading:** Dotenv (loads `.credentials` and `.env`)

## Symbols & Regions

```ruby
REGIONS = {
  us:     %w[SPY QQQ AAPL MSFT GOOGL AMZN NVDA JPM],
  japan:  %w[EWJ TM SONY],
  europe: %w[VGK ASML SAP BP]
}
```

Japan and Europe data use US-listed ETFs (EWJ, VGK) as proxies. Direct exchange APIs require paid access.

## Recommendations Page

`/recommendations` redirects permanently (301) to `/dashboard` as of main.rb:42. Signals are shown inline on the dashboard.
