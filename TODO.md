# TODO — T Money Terminal Enhancement Roadmap

Prioritized list of enhancements to make the terminal meaningfully more useful to an investor. Each item includes **what**, **why**, and — where relevant — **how to sign up** and **integration notes**.

Scope constraints:
- Free APIs only. Rate limits must be handled in code (caching + throttled refresh, as already established in `@/Users/outten/src/t-money-terminal/app/market_data_service.rb` and `@/Users/outten/src/t-money-terminal/scripts/refresh_cache.rb`).
- Reuse the hierarchical disk cache under `data/cache/` (TTL: 1 hour). Any new data category should get its own subdirectory (e.g. `data/cache/fundamentals/`, `data/cache/options/`, `data/cache/news/`).

Legend: **[P0]** core value, **[P1]** high ROI, **[P2]** nice-to-have, **[P3]** stretch.

---

## 🚧 Implementation Status

### Section 1 — Data Sources (✅ complete)
All provider modules live under `@/Users/outten/src/t-money-terminal/app/providers/` and are loadable via `require_relative 'providers'` (`@/Users/outten/src/t-money-terminal/app/providers.rb`).

| § | Module | File | Namespace on disk |
|---|---|---|---|
| 1.1 | `Providers::FmpService` | `@/Users/outten/src/t-money-terminal/app/providers/fmp_service.rb` | `data/cache/fmp/` |
| 1.2 | `Providers::PolygonService` | `@/Users/outten/src/t-money-terminal/app/providers/polygon_service.rb` | `data/cache/polygon/` |
| 1.3 | `Providers::FredService` | `@/Users/outten/src/t-money-terminal/app/providers/fred_service.rb` | `data/cache/fred/` |
| 1.4 | `Providers::NewsService` | `@/Users/outten/src/t-money-terminal/app/providers/news_service.rb` | `data/cache/news/` |
| 1.6 | `Providers::StooqService` | `@/Users/outten/src/t-money-terminal/app/providers/stooq_service.rb` | `data/cache/stooq/` |
| 1.8 | `Providers::EdgarService` | `@/Users/outten/src/t-money-terminal/app/providers/edgar_service.rb` | `data/cache/edgar/` |

Shared infra: `Providers::CacheStore` (hierarchical disk cache, TTL-based) and `Providers::Throttle` (thread-safe min-interval gate, no-op in test env) in `@/Users/outten/src/t-money-terminal/app/providers/cache_store.rb`. HTTP helper in `@/Users/outten/src/t-money-terminal/app/providers/http_client.rb`.

Specs: 20 new examples in `@/Users/outten/src/t-money-terminal/spec/providers_spec.rb`. `make test` → 75 examples, 0 failures.

**Cache warm-up ✅**
- New script `@/Users/outten/src/t-money-terminal/scripts/refresh_providers.rb` warms FRED, Stooq, FMP, Finnhub news caches. Polygon options are opt-in via `--options`.
- `make refresh-providers` — warm provider caches only.
- `make refresh-all` — `refresh-cache` (market data) + `refresh-providers` in one command.
- `make refresh-symbol SYMBOL=AAPL` now warms both market data and provider caches for the given symbol.

**FMP free-tier compatibility ✅**
- `Providers::FmpService` switched from `/api/v3/` (paid) to `/stable/` endpoints with query-param symbol. Verified working on the free key.
- `next_earnings` now uses the shared `/earnings-calendar` endpoint (the per-symbol `/earnings` is paywalled) and filters in Ruby — one calendar fetch serves every symbol.

### Section 2 — Deeper Analysis (P0 + P1 complete ✅)

Pure-Ruby analytics modules under `@/Users/outten/src/t-money-terminal/app/analytics/`, aggregated via `@/Users/outten/src/t-money-terminal/app/analytics.rb`:

| § | Module | File |
|---|---|---|
| 2.1 | `Analytics::Indicators` — SMA, EMA, MACD, RSI (Wilder), Bollinger Bands | `@/Users/outten/src/t-money-terminal/app/analytics/indicators.rb` |
| 2.2 | `Analytics::Risk` — returns, CAGR, ann. vol, Sharpe, Sortino, max DD, VaR (historical + parametric), beta, correlation, date alignment | `@/Users/outten/src/t-money-terminal/app/analytics/risk.rb` |
| 2.3 | `Analytics::BlackScholes` — European price, full Greeks (Δ/Γ/Vega/Θ/ρ), implied vol (bisection), historical vol | `@/Users/outten/src/t-money-terminal/app/analytics/black_scholes.rb` |

Specs: 37 new examples in `@/Users/outten/src/t-money-terminal/spec/analytics_spec.rb` with textbook golden values (ATM call ≈ 10.4506, Δ ≈ 0.6368, etc). `make test` → **112 examples, 0 failures.**

Wired into `@/Users/outten/src/t-money-terminal/views/analysis.erb`:
- **Technical Indicators** — SMA 50 / SMA 200 / RSI(14) / MACD(12,26,9) / Bollinger(20, 2σ) with human-readable signal column.
- **Risk & Performance** — ann. return, ann. vol, Sharpe, Sortino, max DD, VaR 95% (historical + parametric), Beta vs SPY. Uses FRED 3-Mo treasury as the risk-free rate.
- **Black-Scholes (ATM, 30-day)** — illustrative call/put price + full Greeks using 1-year realised vol and FRED `rf`.

Deferred: §2.4 Monte Carlo, §2.6 portfolio tools. §2.5 DCF is already live via `Providers::FmpService#dcf`.

**Wired into views ✅**
- `@/Users/outten/src/t-money-terminal/views/analysis.erb` now renders: Fundamentals & Ratios (FMP), DCF Valuation with margin of safety, Upcoming Earnings, Latest News (Finnhub → NewsAPI fallback). Fundamentals/DCF are automatically suppressed for ETFs.
- `@/Users/outten/src/t-money-terminal/views/dashboard.erb` now shows: Macro Snapshot (Fed Funds, 3-Mo / 10-Yr Treasury, CPI, Unemployment, VIX — FRED) and International Indices (Nikkei, DAX, FTSE, CAC, Hang Seng — Stooq).
- Route handlers in `@/Users/outten/src/t-money-terminal/app/main.rb` use a new `safe_fetch` helper so any provider failure (missing key, 429, network error) yields `nil` and the page still renders.
- Styles added in `@/Users/outten/src/t-money-terminal/public/style.css` (`.macro-panel`, `.macro-grid`, `.macro-card`, `.news-list`, `.news-item`, `.news-headline`, etc.) with dark-mode variants.

---

## 1. Data Sources — New Free APIs to Integrate

### 1.1 [P0] Financial Modeling Prep (FMP) — fundamentals & ratios ✅ implemented
- **What**: Income statement, balance sheet, cash flow, key ratios (P/E, P/B, ROE, Debt/Equity), DCF valuation, earnings calendar, insider trading.
- **Why**: Currently the app has only quote + analyst consensus + hardcoded ETF metadata. Fundamentals are the single biggest gap for "is this a good buy?" decisions.
- **Signup**: https://site.financialmodelingprep.com/developer/docs — free tier: 250 requests/day.
- **Env var**: `FMP_API_KEY` in `.credentials`.
- **Integration**: Add `MarketDataService.fundamentals(symbol)`, `.ratios(symbol)`, `.earnings_calendar(symbol)`. Cache under `data/cache/fundamentals/SYMBOL.json` with 24 h TTL (fundamentals change slowly).
- **Rate limit strategy**: 250/day → ~10/hr. Pre-warm via `scripts/refresh_cache.rb` once/day; never fetch on page load unless cache miss.

### 1.2 [P0] Polygon.io — options chains & tick-level trades (free tier) ✅ implemented
- **What**: Options chains, IV, open interest, trades, aggregates. 5 req/min free.
- **Why**: Enables Black-Scholes pricing validation, IV surface, put/call ratio.
- **Signup**: https://polygon.io/ — free tier: 5 req/min, end-of-day data.
- **Env var**: `POLYGON_API_KEY`.
- **Integration**: New module `app/options_service.rb`. Cache chains per `(symbol, expiry)` for 1 h. Enforce 12 s between calls (matches current Alpha Vantage discipline).

### 1.3 [P1] FRED (Federal Reserve Economic Data) — macro context ✅ implemented
- **What**: Fed funds rate, CPI, unemployment, 10Y treasury yield, yield curve.
- **Why**: Risk-free rate is required for Black-Scholes and Sharpe ratio. Macro context adds a "Macro" dashboard panel.
- **Signup**: https://fred.stlouisfed.org/docs/api/api_key.html — free, unlimited with key.
- **Env var**: `FRED_API_KEY`.
- **Integration**: `MacroDataService.risk_free_rate` (series `DGS10` or `DGS3MO`), cached daily. Used by Black-Scholes (see §2.3) and dashboard "Macro" card.

### 1.4 [P1] NewsAPI + Finnhub News — headlines & sentiment ✅ implemented
- **What**: Per-symbol news feed with timestamps and sources.
- **Why**: Price movements without context are noise. A news panel on `/analysis/:symbol` explains *why* a stock moved.
- **Signup**:
  - Finnhub news is already available with existing `FINNHUB_API_KEY` (`/news` and `/company-news` endpoints).
  - NewsAPI: https://newsapi.org/register — 100 req/day free.
- **Integration**: Start with Finnhub (zero new signup). Add `MarketDataService.news(symbol, days: 7)`, cache `data/cache/news/SYMBOL.json` with 1 h TTL.

### 1.5 [P2] Alpha Vantage Technical Indicators (already have key)
- **What**: SMA, EMA, RSI, MACD, Bollinger Bands from AV — but these are easier computed locally from cached historicals (see §2.1). Keep AV as verification fallback only.
- **Action**: *Do not add new AV endpoints*. Compute indicators in Ruby from existing Yahoo/Tiingo OHLCV cache to avoid burning the 25/day AV budget.

### 1.6 [P2] Stooq — international indices (free, no key) ✅ implemented
- **What**: CSV endpoints for Nikkei 225, DAX, FTSE, CAC 40, Hang Seng.
- **Why**: Region pages (`/japan`, `/europe`) currently proxy through US-listed ETFs (EWJ, VGK). Stooq gives actual local index values.
- **URL**: `https://stooq.com/q/d/l/?s=^nkx&i=d` (Nikkei daily CSV). No auth.
- **Integration**: `MacroDataService.index(:nikkei | :dax | :ftse)`. Cache 1 h.

### 1.7 [P2] CoinGecko — crypto (if user wants to expand beyond equities)
- **Signup**: None required for free tier (30 req/min).
- Defer until user confirms crypto scope.

### 1.8 [P3] SEC EDGAR — 10-K / 10-Q / 8-K filings ✅ implemented (thin)
- **What**: Direct filings index per ticker/CIK.
- **Signup**: None. Requires custom `User-Agent` header per SEC rules.
- **Why**: Link directly to latest 10-Q from `/analysis/:symbol`.
- **Integration**: `EdgarService.latest_filings(cik)` — cache 24 h.

---

## 2. Deeper Analysis — Industry-Standard Algorithms

All of these should live in a new `app/analytics/` directory (e.g. `analytics/indicators.rb`, `analytics/black_scholes.rb`, `analytics/risk.rb`). They operate on **already-cached** OHLCV data, so they cost zero API calls.

### 2.1 [P0] Technical indicators computed locally ✅ implemented
Implement in pure Ruby from cached historicals:
- **SMA** (20, 50, 200 day) — trend baseline.
- **EMA** (12, 26) — input to MACD.
- **MACD** (12/26/9) — momentum crossover signal.
- **RSI** (14) — overbought (>70) / oversold (<30).
- **Bollinger Bands** (20, 2σ) — volatility envelope.
- **ATR** (14) — average true range for stop-loss sizing.
- **OBV** (On-Balance Volume) — volume-confirmed trend.
- **VWAP** — intraday fair value (requires intraday bars; defer to P1 once intraday cache exists).

**Upgrade to `RecommendationService`**: Replace the current `change > 1% → BUY` logic with a composite score blending:
- Analyst consensus (current).
- Trend: price vs SMA50 and SMA200 (golden cross / death cross).
- Momentum: RSI + MACD histogram sign.
- Volume confirmation: OBV slope.

Weight each factor, normalize to [-1, 1], map to BUY/HOLD/SELL with configurable thresholds.

### 2.2 [P1] Risk & performance statistics ✅ implemented
Per symbol on `/analysis/:symbol`:
- **Annualized return & volatility** (from daily log returns).
- **Sharpe ratio** (uses FRED risk-free rate from §1.3).
- **Sortino ratio** (downside deviation).
- **Max drawdown** & drawdown duration.
- **Beta vs SPY** (rolling 1-year regression on daily returns).
- **Value-at-Risk (VaR)** — 95% 1-day parametric and historical.
- **Correlation matrix** across region — new `/correlations` page.

### 2.3 [P1] Black-Scholes options pricing ✅ implemented
- **Inputs**: spot (from quote), strike, expiry (T in years), risk-free rate (FRED), volatility (see below), option type.
- **Outputs**: theoretical call/put price, **Greeks** (Δ, Γ, Θ, Vega, Rho).
- **Volatility input**: offer toggle between (a) historical 30-day realized vol, (b) implied vol from Polygon chain (§1.2).
- **UI**: New `/options/:symbol` page with a chain table annotated with theoretical price, IV, moneyness, and a Δ/Γ curve.
- **Library**: pure Ruby (cdf via `Math.erf`); no gem needed. ~60 LOC.

### 2.4 [P2] Monte Carlo simulation
- GBM price paths (10k runs, 252-day horizon) using μ and σ from historicals.
- Outputs: p10/p50/p90 terminal price fan chart, probability of hitting target price.
- Render on `/analysis/:symbol` as an expandable section.

### 2.5 [P2] DCF valuation
- Pull 5y historical FCF from FMP (§1.1) → project → discount at WACC (use 10Y treasury + equity risk premium ≈ 5%).
- Show intrinsic value vs current price with margin-of-safety flag.

### 2.6 [P3] Portfolio tools (requires user-owned state)
- User-defined watchlist / portfolio stored in `data/portfolio.json`.
- Efficient frontier (Markowitz) across watchlist.
- Portfolio Sharpe, weights by mean-variance optimization.

---

## 3. Charting Upgrades (Industry-Standard Finance Visuals)

Current charts (`@/Users/outten/src/t-money-terminal/public/app.js:17-147`) are simple Chart.js line/bar. Finance users expect candlesticks, volume, and indicator overlays.

### 3.1 [P0] Candlestick + volume with hash marks (OHLC)
- **Library**: Replace `chart.js` with **lightweight-charts** (TradingView, ~45 KB, free, MIT). Purpose-built for finance: candlesticks, OHLC bars (aka hash-mark bars), volume histograms, indicator overlays, crosshair with price/time readout.
- **Alternative**: `chartjs-chart-financial` plugin keeps Chart.js but is less polished.
- **Requirement**: backend must return `{ date, open, high, low, close, volume }`. The `MarketDataService.historical` already fetches OHLCV from Yahoo — verify the shape is preserved and expose it on `/api/candle/:symbol/:period`.

### 3.2 [P0] Indicator overlays on the price chart
- SMA 20/50/200 lines.
- Bollinger Bands envelope.
- Volume subpanel with green/red bars matching candle direction.

### 3.3 [P1] Separate oscillator subpanels
- RSI(14) panel with 30/70 reference lines.
- MACD(12/26/9) panel with signal line and histogram.

### 3.4 [P1] Chart interactivity
- Crosshair with OHLCV tooltip at cursor.
- Period toggle preserves chart type (candle vs line) and overlay selections.
- Log-scale toggle (critical for 5y views).
- Drawing tools: horizontal support/resistance lines (stretch).

### 3.5 [P2] Heat map for region pages
- Treemap (sector-weighted) with color = % change. `lightweight-charts` doesn't ship this — use `d3.js` or `echarts-for-sector-treemap` snippet.

### 3.6 [P2] Correlation heatmap
- For the `/correlations` page from §2.2. Simple `<canvas>` + manual draw, no lib needed.

### 3.7 [P3] Options visualizations
- Volatility smile / term structure.
- Payoff diagram builder (long call, covered call, vertical spread, iron condor).

---

## 4. UX / Product Features

### 4.1 [P1] Search box — jump to any symbol
Currently symbols are hardcoded in `REGIONS`. Add a top-nav search that validates against a symbol list (seed from FMP `/stock/list` cached weekly) and routes to `/analysis/:symbol`.

### 4.2 [P1] Watchlist (client-side → server-side)
- Phase 1: `localStorage` list on the dashboard.
- Phase 2: persist to `data/watchlist.json` (single-user assumption).

### 4.3 [P1] Earnings & dividend calendar widget
- Sourced from FMP (§1.1). Show on dashboard: "Upcoming this week."

### 4.4 [P2] Price alerts
- User sets threshold on `/analysis/:symbol`. A background job (cron via `make` target) checks every 15 min and writes to `data/alerts.log`. Email/webhook delivery is stretch.

### 4.5 [P2] CSV / JSON export
- "Download" button on analysis page → dumps historicals + indicators for the current period.

### 4.6 [P2] Compare mode
- `/compare?symbols=AAPL,MSFT,GOOGL` — normalized price chart (rebased to 100) for multi-symbol performance comparison.

---

## 5. Infrastructure / Code Quality

### 5.1 [P1] Refactor `MarketDataService`
- Current file is ~940 LOC (`@/Users/outten/src/t-money-terminal/app/market_data_service.rb`). Split by provider: `providers/tiingo.rb`, `providers/alpha_vantage.rb`, `providers/finnhub.rb`, `providers/yahoo.rb`. Keep `MarketDataService` as the cache + waterfall orchestrator.

### 5.2 [P1] Background refresh job
- `scripts/refresh_cache.rb` exists for manual runs. Add a `scripts/scheduler.rb` loop (or systemd/launchd plist example in docs) that refreshes tiered data on different cadences:
  - Quotes: every 15 min during market hours.
  - Fundamentals: daily 03:00 local.
  - Analyst recs: weekly.
  - Macro: daily.

### 5.3 [P2] Expanded test coverage
- Current specs are smoke tests. Add unit tests for every new analytic (§2) with golden-value fixtures (e.g. BS price for known inputs should match textbook value within 1e-6).

### 5.4 [P2] Provider health dashboard
- Extend `/admin/cache` with per-provider success/failure counters from the last N calls (requires tiny metrics ring buffer in `MarketDataService`).

---

## 6. Recommended Execution Order

1. **§1.3 FRED** + **§1.1 FMP** signup (5 min each) — unblocks §2.2, §2.3, §2.5.
2. **§2.1 technical indicators** (pure Ruby, no API cost) — immediate user value.
3. **§3.1 candlestick chart** via `lightweight-charts` — the single most visible UX upgrade.
4. **§2.2 risk stats** — trivial once returns are computed.
5. **§3.2 indicator overlays** — combines §2.1 + §3.1.
6. **§1.4 news panel** — uses existing Finnhub key, zero new signup.
7. **§1.2 Polygon** + **§2.3 Black-Scholes** + **§3.7 options UI** — one coherent milestone.
8. **§4.1 search + §4.2 watchlist** — opens the app beyond the 15 hardcoded symbols.
9. Everything else as appetite allows.

---

## 7. API Signup Checklist (quick reference)

Add to `.credentials`:

```
# Already present
TIINGO_API_KEY=...
ALPHA_VANTAGE_API_KEY=...
FINNHUB_API_KEY=...

# New
FMP_API_KEY=...          # https://site.financialmodelingprep.com/developer/docs  (250/day)
POLYGON_API_KEY=...      # https://polygon.io/                                    (5/min)
FRED_API_KEY=...         # https://fred.stlouisfed.org/docs/api/api_key.html      (unlimited)
NEWSAPI_KEY=...          # https://newsapi.org/register    (optional; 100/day)
```

Update `@/Users/outten/src/t-money-terminal/CREDENTIALS.md` with the same list and one-line descriptions once keys are provisioned.
