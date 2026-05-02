# Agent Instructions — T Money Terminal

Operational reference for agents (and humans) working in this repo. The
canonical user-facing description lives in [README.md](README.md); this
file focuses on architecture, gotchas, and conventions that aren't
obvious from a quick code read.

## Setup & credentials

Credentials live in `.credentials` (NOT `.env`). Both files are auto-loaded
by Dotenv but `.credentials` is canonical.

```ruby
# app/main.rb and app/market_data_service.rb
Dotenv.load(File.expand_path('../../.credentials', __FILE__))
```

**Wired keys** (all optional; the app degrades gracefully):
- `TIINGO_API_KEY` — quotes + historical
- `ALPHA_VANTAGE_API_KEY` — fallback quote / weekly historical (5/min, 25/day)
- `FINNHUB_API_KEY` — analyst, profile, news, candles (paywalled now)
- `FMP_API_KEY` — fundamentals + DCF + historical fallback (**per-symbol whitelist**)
- `POLYGON_API_KEY` — daily aggregates + options (5/min)
- `FRED_API_KEY` — macro snapshot (unlimited)
- `NEWSAPI_KEY` — news fallback
- `ALERT_WEBHOOK_URL` / `ALERT_NTFY_TOPIC` / `ALERT_EMAIL_TO` + `ALERT_SMTP_*` — alert delivery

See [CREDENTIALS.md](CREDENTIALS.md) for the full walkthrough including FMP free-tier paywall behaviour. **Never commit `.credentials` or `.env`** — both are git-ignored.

## Development commands

```bash
make install                 # bundle install
make run                     # auto-reload via rerun → http://localhost:4567 (alias: make dev)
make serve                   # one-shot run, no auto-reload
make test                    # RSpec — currently 453 examples
make refresh-cache           # warm market-data cache for the universe
make refresh-providers       # warm FMP / FRED / News / Stooq
make refresh-all             # both — REGIONS ∪ portfolio ∪ watchlist
make refresh-symbol SYMBOL=X # one symbol end-to-end
make scheduler TIER=quotes   # tiered cache refresh; tiers = quotes/fundamentals/analyst/macro/alerts/all
make cache-status            # cache age / staleness report
make check-alerts            # evaluate active alerts; dispatch via Notifiers
```

`make run` reads [.rerun](.rerun) for watch dirs and ignore globs. **`.rerun` does NOT support `#` comments** — its contents are shell-split verbatim. Keep it option-only.

## Caching architecture

**Two-tier in-memory cache** (`MarketDataService`):
- `@cache` — live; gated by `cache_entry_fresh?` against `effective_ttl`. Read by `read_live_cache`.
- `@persistent_cache` — fallback; survives `bust_cache!`. Returned when live is empty.
- `@cache_timestamps` — per-key timestamp for TTL checks.

**Disk cache** at `data/cache/`:
```
data/cache/
├── quotes/<SYM>.json
├── historical/<SYM>_<PERIOD>.json
├── analyst/<SYM>.json
├── profiles/<SYM>.json
├── fmp/                            # provider-specific caches via Providers::CacheStore
│   └── _paywalled_/<SYM>.txt       # FMP 402 tombstones (24h TTL)
├── polygon/<key>.json
├── fred/<key>.json
├── news/<SYM>_<DAYS>.json
├── stooq/<index>.json
├── correlations/<period>_<sha>.json
└── market_cache.json               # legacy monolithic cache; loaded into BOTH @cache and @persistent_cache at boot
```

**Market-aware TTL**:
- `CACHE_TTL = 3600` (1h) during US market hours (M–F 09:30–16:00 ET)
- `CACHE_TTL_CLOSED = 12h` outside market hours
- Override via `ENV['MARKET_OPEN']=1|0|true|false` for tests.

**Rendering contract** (load-bearing — break it and pages get slow):

```
Page renders MUST be cache-only.
  /portfolio → MarketDataService.quote_cached (TTL-bypassing)
  /portfolio → RecommendationService.signal_for(sym, cached_only: true)
  /analysis  → uses live fetch (intentional — first view warms cache)

Network events ONLY happen via:
  - Broker imports (POST /portfolio/import/fidelity → primes quote cache)
  - Scheduler (make scheduler TIER=...)
  - Admin refresh (POST /admin/refresh/{symbol,all})
  - HistoricalPrefetcher (background thread fired by import)
  - First /analysis/:symbol view (lazy populates analyst/historical)
```

If you change `valuate_position` or `annotate_portfolio_signals!`, run [spec/portfolio_perf_spec.rb](spec/portfolio_perf_spec.rb) — it asserts hard `not_to receive(:fetch_quote)` / `not_to receive(:get_response)` on `/portfolio`.

## Stores (file-backed, mutex-guarded, atomic-rename writes)

| Store | File | Purpose |
|---|---|---|
| [PortfolioStore](app/portfolio_store.rb) | `data/portfolio.json` | Multi-lot positions; FIFO close (tax-aware: each closed lot tagged with holding_period via [TaxLot](app/tax_lot.rb)); closed lots retained inline for audit |
| [TradesStore](app/trades_store.rb) | `data/trades.json` | Append-only BUY/SELL log; SELLs include short/long-term P&L split + [WashSale](app/wash_sale.rb) flags |
| [WatchlistStore](app/watchlist_store.rb) | `data/watchlist.json` | Ordered, deduped symbol list |
| [AlertsStore](app/alerts_store.rb) | `data/alerts.json` | Threshold alerts; triggered alerts append to `alerts_triggered.log` |
| [SymbolIndex](app/symbol_index.rb) | `data/symbols_extended.json` | Runtime ticker discovery extensions |
| [ImportSnapshotStore](app/import_snapshot_store.rb) | `data/imports/<source>/<basename>.json` | Per-source broker import snapshots (audit + drift) |
| [ProfileStore](app/profile_store.rb) | `data/profile.json` | User investment profile (current_age, retirement_age, risk_tolerance, federal LTCG / ordinary rates, optional state rate, NIIT) — drives the [TaxHarvester](app/tax_harvester.rb) analysis at `/portfolio/tax-harvest` |

All mutating stores use `MUTEX.synchronize` + write-to-`.tmp`-then-rename for crash safety.

## Provider waterfall

Each fetch path tries providers in order; first non-empty wins.

| Resource | Order | Module |
|---|---|---|
| Quote | Tiingo → Alpha Vantage → Finnhub → Yahoo | `MarketDataService.try_providers` |
| Historical | Yahoo → FMP → **Polygon** → Finnhub → Tiingo → AV-weekly | `MarketDataService.fetch_historical` + `prefetch_all_historical` |
| Analyst | Finnhub | `MarketDataService.fetch_analyst_recommendations` |
| Profile | ETF_PROFILES (4 hardcoded) → Finnhub | `MarketDataService.fetch_company_profile` |
| Fundamentals (key metrics, ratios, DCF, earnings) | FMP only | `Providers::FmpService` |
| Macro | FRED | `Providers::FredService` |
| News | Finnhub → NewsAPI fallback | `Providers::NewsService` |
| International indices | Stooq | `Providers::StooqService` |

Polygon was added (PR #2) because FMP free tier paywalls per-symbol — see [Common Gotchas](#common-gotchas).

## RefreshUniverse — single source of truth

[app/refresh_universe.rb](app/refresh_universe.rb) is the canonical "list of symbols this app cares about" used by every refresh / prefetch / scheduler script.

- Default: `REGIONS ∪ PortfolioStore ∪ WatchlistStore`
- Opt-in: `include_extensions: true` (every discovered ticker — accumulates), `include_curated: true` (CURATED constant)
- Filter: drops anything that fails `SymbolIndex.looks_like_ticker?` (excludes 9-digit CUSIPs Fidelity sometimes lands in the Symbol column)

## HealthRegistry

[app/health_registry.rb](app/health_registry.rb) — bounded ring buffer of provider call observations. Surfaces at `/admin/health`. `HealthRegistry.degraded` powers the dashboard banner.

`Providers::HttpClient.get_json` records every call with status code + reason. Legacy `MarketDataService.fetch_from_*` paths use `HealthRegistry.measure` wrappers.

In-memory only; clears on process restart. Tests opt in via `ENV['HEALTH_REGISTRY']=1`.

## Project structure

```
app/
  main.rb                  # Sinatra routes (TMoneyTerminal class) — ~1,000 LOC
  market_data_service.rb   # Provider waterfall + cache + market-aware TTL — ~1,400 LOC
  recommendation_service.rb
  providers/               # FMP, Polygon, FRED, News, Stooq, EDGAR + cache_store + http_client + throttle
  analytics/               # Indicators, risk, Black-Scholes (pure Ruby)
  symbol_index.rb          # Curated + REGIONS + runtime extensions; TICKER_PATTERN guard
  portfolio_store.rb       # Multi-lot; FIFO close
  trades_store.rb          # Append-only history (short/long-term + wash-sale flags)
  tax_lot.rb               # Holding-period classifier (short ≤ 1yr / long > 1yr)
  wash_sale.rb             # IRS wash-sale risk flagging on loss-sells (±30d)
  profile_store.rb         # User profile (age, retirement, risk tolerance, tax rates, NIIT) at data/profile.json
  tax_harvester.rb         # Loss-harvest candidate ranking, tax-savings estimate, ST→LT crossings, replacement suggestions
  portfolio_history.rb     # Pivots ImportSnapshotStore into total + per-symbol time series; sparklines; underwater_streak
  retirement_projection.rb # Required-CAGR math (current → target over years); /portfolio retirement-progress section
  analytics/benchmark.rb   # Lot-weighted portfolio return vs SPY (cache-only)
  fidelity_importer.rb     # Broker CSV → reconciliation
  import_snapshot_store.rb # Per-source snapshot persistence
  portfolio_diff.rb        # Snapshot-to-snapshot drift math
  refresh_universe.rb      # Single source of truth for symbol set
  refresh_tracker.rb       # In-memory job tracker for background refreshes
  historical_prefetcher.rb # Async prefetch on import
  health_registry.rb       # Per-provider success/error/latency
  watchlist_store.rb / alerts_store.rb / notifiers.rb / correlation_store.rb
views/                     # ERB templates
public/                    # style.css + app.js (chart) + features.js (search/watchlist/alerts/portfolio)
scripts/                   # refresh_cache, refresh_providers, scheduler, check_alerts, cache_status
spec/                      # 17 spec files, 453 examples (tax_lot_spec.rb covers TaxLot/WashSale/Benchmark; tax_harvest_spec.rb covers ProfileStore+TaxHarvester+routes; portfolio_history_spec.rb covers PortfolioHistory + Fidelity backfill + history routes; retirement_projection_spec.rb covers required-CAGR math)
data/                      # All app state (git-ignored except hierarchical cache structure markers)
.github/workflows/ci.yml   # GitHub Actions — RSpec + scripts syntax check on push to main + every PR
```

## Testing

```bash
make test                                  # full suite (453 examples, 0 failures)
bundle exec rspec spec/feature_spec.rb     # one file
bundle exec rspec spec/feature_spec.rb:42  # one example
```

Tests run with `ENV['RACK_ENV'] = 'test'`. CacheStore + Throttle + HealthRegistry + HistoricalPrefetcher are no-ops in test env unless explicitly opted in via env var (`HEALTH_REGISTRY=1`, `HISTORICAL_PREFETCH=1`, `MARKET_OPEN=1`).

CI is configured at [.github/workflows/ci.yml](.github/workflows/ci.yml) — runs on push to `main` and every PR.

## Common gotchas

1. **FMP free tier whitelists symbols.** AAPL/MSFT pass; ADRs / mutual funds / most ETFs return HTTP 402 with "This value set for 'symbol' is not available." On 402 we write a 24h tombstone at `data/cache/fmp/_paywalled_/<SYM>.txt` and short-circuit future requests. If you see `:error` ticks for FMP in `/admin/health`, the symbol is just paywalled — not broken.

2. **Yahoo IP-throttles** on personal-machine usage. The waterfall handles this; Polygon (with `POLYGON_API_KEY`) is the practical primary historical source for users hitting Yahoo 429s.

3. **Cache-only render contract.** `/portfolio` and `/api/portfolio` MUST NOT fire providers. Use `MarketDataService.quote_cached` and `RecommendationService.signal_for(sym, cached_only: true)`. The hard assertions are in [spec/portfolio_perf_spec.rb](spec/portfolio_perf_spec.rb).

4. **Process-restart cache survival.** `load_from_disk` populates BOTH `@cache` and `@persistent_cache` — older code only populated the persistent layer, which made every post-restart render fan out to providers. Don't revert that.

5. **`.rerun` config** is shell-split verbatim — no `#` comments. Documentation lives in the [Makefile](Makefile)'s `run` target.

6. **CUSIP filter.** Fidelity sometimes lands 9-digit CUSIPs (e.g. `84679Q106`) in the Symbol column. `SymbolIndex.looks_like_ticker?` filters them out — they aren't quotable so refreshing them just wastes rate-limit budget.

7. **Multi-lot semantics.** PortfolioStore allows multiple lots per symbol. `find(symbol)` returns an aggregated position with weighted-avg cost basis; `lots_for(symbol)` returns each lot. `close_shares_fifo` walks oldest-first and may split the last partially-closed lot.

8. **Imports replace, manual entries persist.** Fidelity import wipes lots for symbols *in the file* and replaces with the broker's single-lot aggregate. Symbols *not* in the file are left alone — manual `add_lot` calls persist.

9. **Historical prefetch on import** is asynchronous (Thread). Don't `Thread.list.each(&:join)` in tests — you'll deadlock on the stdlib Timeout thread. Stub `HistoricalPrefetcher.prefetch_async` instead.

## Symbols & regions

```ruby
MarketDataService::REGIONS = {
  us:     %w[SPY QQQ AAPL MSFT GOOGL AMZN NVDA JPM],
  japan:  %w[EWJ TM SONY],
  europe: %w[VGK ASML SAP BP]
}
```

Japan and Europe data use US-listed ETFs (EWJ, VGK) as proxies. Direct exchange APIs require paid access.

`SymbolIndex` adds a curated ~40-symbol list (TSLA / NFLX / etc.) plus a runtime extension store for tickers discovered through search or imports.

## Documentation files

- [README.md](README.md) — user-facing overview
- **[AGENTS.md](AGENTS.md)** — this file (developer/agent reference)
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — PR workflow (branch / commit style / tests / CI / merge)
- [TODO.md](TODO.md) — roadmap (shipped + open + dropped)
- [CREDENTIALS.md](CREDENTIALS.md) — API key setup walkthrough
- [Instructions.md](Instructions.md) — user-facing how-to
- [DEVELOPER.md](DEVELOPER.md) — pointer to AGENTS.md (kept for legacy reference)
- [SPEC.md](SPEC.md) — original project brief (frozen)
- [ANALYSIS.md](ANALYSIS.md) — data-source positioning (Bloomberg-comparison framing)

**Workflow rule**: every PR that changes behaviour should update the relevant docs in the same PR — see [CONTRIBUTING.md](CONTRIBUTING.md) and the saved-memory note `feedback_update_docs_each_pr`.
