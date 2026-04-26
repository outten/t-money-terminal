# TODO — T Money Terminal Enhancement Roadmap

Prioritized list of enhancements to make the terminal meaningfully more useful to an investor. Each item includes **what**, **why**, and — where relevant — **how to sign up** and **integration notes**.

**Scope constraints**
- Free APIs only. Rate limits must be handled in code (caching + throttled refresh, as already established in [app/market_data_service.rb](app/market_data_service.rb) and [scripts/refresh_cache.rb](scripts/refresh_cache.rb)).
- Reuse the hierarchical disk cache under `data/cache/` (TTL: 1 hour). Any new data category gets its own subdirectory (e.g. `data/cache/fundamentals/`, `data/cache/options/`, `data/cache/news/`).

**Legend** — **[P0]** core value · **[P1]** high ROI · **[P2]** nice-to-have · **[P3]** stretch.

---

## Shipped

Condensed status of the sections that are already live. Pointers are kept so future work can build on the same primitives.

### §1 Data sources — all primary providers wired
Every provider module lives under [app/providers/](app/providers/) and is loadable via `require_relative 'providers'` ([app/providers.rb](app/providers.rb)).

| § | Module | File | Cache namespace |
|---|---|---|---|
| 1.1 | `Providers::FmpService` | [fmp_service.rb](app/providers/fmp_service.rb) | `data/cache/fmp/` |
| 1.2 | `Providers::PolygonService` | [polygon_service.rb](app/providers/polygon_service.rb) | `data/cache/polygon/` |
| 1.3 | `Providers::FredService` | [fred_service.rb](app/providers/fred_service.rb) | `data/cache/fred/` |
| 1.4 | `Providers::NewsService` | [news_service.rb](app/providers/news_service.rb) | `data/cache/news/` |
| 1.6 | `Providers::StooqService` | [stooq_service.rb](app/providers/stooq_service.rb) | `data/cache/stooq/` |
| 1.8 | `Providers::EdgarService` (thin) | [edgar_service.rb](app/providers/edgar_service.rb) | `data/cache/edgar/` |

Shared infra in [cache_store.rb](app/providers/cache_store.rb): `Providers::CacheStore` (hierarchical disk cache, TTL-based) and `Providers::Throttle` (thread-safe min-interval gate, no-op in test env). HTTP helper in [http_client.rb](app/providers/http_client.rb).

FMP runs on the free `/stable/` endpoints (not paywalled `/api/v3/`). `next_earnings` uses the shared `/earnings-calendar` endpoint and filters in Ruby — one fetch serves every symbol.

Cache warm-up: [scripts/refresh_providers.rb](scripts/refresh_providers.rb), `make refresh-providers`, `make refresh-all`, `make refresh-symbol SYMBOL=…`.

### §2 Analytics — indicators, risk, Black-Scholes
Pure-Ruby modules under [app/analytics/](app/analytics/), aggregated via [app/analytics.rb](app/analytics.rb):

| § | Module | File |
|---|---|---|
| 2.1 | `Analytics::Indicators` — SMA, EMA, MACD, RSI (Wilder), Bollinger Bands | [indicators.rb](app/analytics/indicators.rb) |
| 2.2 | `Analytics::Risk` — returns, CAGR, ann. vol, Sharpe, Sortino, max DD, VaR (historical + parametric), beta, correlation, date alignment | [risk.rb](app/analytics/risk.rb) |
| 2.3 | `Analytics::BlackScholes` — European price, full Greeks, implied vol (bisection), historical vol | [black_scholes.rb](app/analytics/black_scholes.rb) |

Wired into [views/analysis.erb](views/analysis.erb): Technical Indicators table, Risk & Performance table (uses FRED 3-Mo treasury as `rf`), and an ATM 30-day Black-Scholes illustration using realised vol. §2.5 DCF is live via `Providers::FmpService#dcf`.

### §3 Charting — candles, overlays, oscillator panes
TradingView lightweight-charts (CDN, 45 KB, MIT). Four synchronized panes: price (candles + SMA 20/50/200 + Bollinger 20/2σ), volume histogram coloured by candle direction, RSI(14) with 30/70 reference lines, MACD(12/26/9) line + signal + coloured histogram. OHLCV flows end-to-end through [app/market_data_service.rb](app/market_data_service.rb) for every provider. `/api/candle/:symbol/:period` returns `{ bars, indicators }` with indicators computed server-side via `Analytics::Indicators`. UX: crosshair readout pill, legend with swatches, period toggle (1d / 1m / 3m / YTD / 1y / 5y), log-scale toggle, ResizeObserver for responsive width, palette auto-swap.

Dashboard additions: Macro Snapshot (Fed Funds, 3-Mo / 10-Yr Treasury, CPI, Unemployment, VIX — FRED) and International Indices (Nikkei, DAX, FTSE, CAC, Hang Seng — Stooq). Analysis additions: Fundamentals & Ratios (FMP), DCF Valuation with margin of safety, Upcoming Earnings, Latest News (Finnhub → NewsAPI fallback). Fundamentals/DCF are suppressed for ETFs. Route handlers use a `safe_fetch` helper so any provider failure yields `nil` and the page still renders.

### §4 UX / product features
- **Search** — [symbol_index.rb](app/symbol_index.rb) provides the universe (every `REGIONS` ticker plus ~40 curated large-caps and sector ETFs). `GET /api/symbols` powers the top-nav autocomplete with ranked prefix/substring matching (exact-symbol → symbol-prefix → name-prefix → substring), keyboard navigation, mouse hover highlight. `TMoneyTerminal::VALID_SYMBOLS` is sourced from `SymbolIndex.symbols`.
- **Watchlist** — [watchlist_store.rb](app/watchlist_store.rb) persists to `data/watchlist.json` (atomic write + mutex). `GET/POST/DELETE /api/watchlist` plus `POST /watchlist/remove` form-fallback. Dashboard "My Watchlist" table + `/analysis/:symbol` ☆/★ toggle.
- **Earnings calendar** — Dashboard "Upcoming Earnings (Next 7 Days)" filtered against REGIONS ∪ curated ∪ watchlist. Gracefully hides if FMP is missing/throttled.
- **Price alerts** — [alerts_store.rb](app/alerts_store.rb) persists to `data/alerts.json`. `GET/POST/DELETE /api/alerts` and an Alerts section on `/analysis/:symbol`. [scripts/check_alerts.rb](scripts/check_alerts.rb) + `make check-alerts` evaluates every active alert, flips `triggered_at` on crossing, and appends to `data/alerts_triggered.log`. Cron: `*/15 9-16 * * 1-5 cd … && make check-alerts`.
- **CSV export** — `GET /api/export/:symbol/:period.csv` returns OHLCV + full indicator series (SMA 20/50/200, Bollinger, RSI, MACD triple). Button on `/analysis/:symbol`.
- **Compare mode** — `/compare?symbols=AAPL,MSFT,GOOGL&period=1y`, rebased-to-100, Chart.js, up to 6 symbols. `GET /api/compare` returns server-computed rebased series.

**Test suite** — 138/138 passing (`make test`): 26 in [spec/section4_spec.rb](spec/section4_spec.rb), 37 in [spec/analytics_spec.rb](spec/analytics_spec.rb), 20 in [spec/providers_spec.rb](spec/providers_spec.rb), plus app and services specs.

---

## Open work

### §2.4 [P2] Monte Carlo simulation
- GBM price paths (10k runs, 252-day horizon) using μ and σ from historicals.
- Outputs: p10/p50/p90 terminal price fan chart, probability of hitting target price.
- Render on `/analysis/:symbol` as an expandable section.
- New file: `app/analytics/monte_carlo.rb`. Reuses cached historicals — zero API cost.

### §2.6 [P3] Portfolio tools (requires user-owned state)
- User-defined portfolio (with weights) stored alongside the existing watchlist in `data/portfolio.json`.
- Efficient frontier (Markowitz) across watchlist using `Analytics::Risk.correlation`.
- Portfolio Sharpe and weights via mean-variance optimization.
- Builds on §2.2 (already shipped) and the existing `WatchlistStore` pattern.

### §3.5 [P2] Sector treemap for region pages
- Treemap (sector-weighted) with colour = % change. lightweight-charts doesn't ship this — use d3.js or ECharts snippet.
- New route `/sectors` or embedded panel on `/region/:name`. Needs sector classification; FMP `/profile` returns `sector`.

### §3.6 [P2] Correlation heatmap
- Needs a new `/correlations` page (or tab on `/compare`) computing pairwise correlation across watchlist/region using `Analytics::Risk.correlation`.
- Plain `<canvas>` + manual draw, no new dependency. Expose via `GET /api/correlations`.

### §3.7 [P3] Options visualisations
- Requires §1.2 (Polygon, already shipped) to source live chains.
- Volatility smile / term structure plot.
- Payoff diagram builder (long call, covered call, vertical spread, iron condor).
- New route `/options/:symbol` with a chain table annotated with theoretical price (via `Analytics::BlackScholes`), IV, moneyness, and Δ/Γ curves.

### §4.5 follow-up [P3] CSV export: honour current chart period
- Today the button on `/analysis/:symbol` pins to `1y`. Wire it to the chart's active period state so the exported range matches what the user is looking at.

### §5.1 [P1] Refactor `MarketDataService`
- Current file is ~940 LOC at [app/market_data_service.rb](app/market_data_service.rb). Split by provider (`providers/tiingo.rb`, `providers/alpha_vantage.rb`, `providers/finnhub.rb`, `providers/yahoo.rb`) following the pattern already established in [app/providers/](app/providers/).
- Keep `MarketDataService` as the cache + waterfall orchestrator.
- Should be mechanical given the existing provider-module template.

### §5.2 [P1] Background refresh scheduler
- [scripts/refresh_cache.rb](scripts/refresh_cache.rb) exists for manual runs. Add a `scripts/scheduler.rb` loop (or a launchd plist / systemd unit example in docs) that refreshes tiered data on different cadences:
  - Quotes: every 15 min during market hours.
  - Fundamentals: daily 03:00 local.
  - Analyst recs: weekly.
  - Macro: daily.
- Pair with the existing `make check-alerts` cron recipe.

### §5.3 [P2] Expanded test coverage
- Analytics already have golden-value fixtures. Extend the same discipline to `MarketDataService` provider branches (cache hit, cache miss, fallback, throttled) once §5.1 splits the providers.

### §5.4 [P2] Provider health dashboard
- Extend `/admin/cache` with per-provider success/failure counters from the last N calls (tiny metrics ring buffer in `MarketDataService`).
- Would also benefit the scheduler in §5.2 (e.g. skip a provider that's been 429ing).

### §1.7 [P2] CoinGecko — crypto scope
- Deferred. No signup, 30 req/min free. Would require its own region (`:crypto`) and mock prices before wiring into the waterfall pattern.

### §1.5 [skip] Alpha Vantage Technical Indicators
- Intentionally not added — indicators are computed locally from cached historicals (see §2.1). Keep AV as the quote fallback only to preserve the 25-req/day budget.

---

## API signup checklist

Add to `.credentials` (all optional — the app degrades gracefully, hiding panels whose provider is unconfigured):

```
# Core market data
TIINGO_API_KEY=...
ALPHA_VANTAGE_API_KEY=...
FINNHUB_API_KEY=...

# Deeper data
FMP_API_KEY=...          # https://site.financialmodelingprep.com/developer/docs  (250/day)
POLYGON_API_KEY=...      # https://polygon.io/                                    (5/min)
FRED_API_KEY=...         # https://fred.stlouisfed.org/docs/api/api_key.html      (unlimited)
NEWSAPI_KEY=...          # https://newsapi.org/register                           (100/day; optional fallback)
```

Update [CREDENTIALS.md](CREDENTIALS.md) with the same list and one-line descriptions when a new key is provisioned.
