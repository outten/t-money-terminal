# TODO — T Money Terminal Roadmap

**Scope constraints**
- Free APIs only. Rate limits are absorbed by code (caching + throttling — see [app/market_data_service.rb](app/market_data_service.rb), [app/providers/cache_store.rb](app/providers/cache_store.rb)).
- New data categories get their own `data/cache/<namespace>/` subdirectory.
- Single-user, file-backed state (`data/portfolio.json`, `data/trades.json`, `data/watchlist.json`, `data/alerts.json`, `data/symbols_extended.json`). A multi-user rebuild moves to SQLite — out of scope.

**Legend** — **[P0]** core value · **[P1]** high ROI · **[P2]** nice-to-have · **[P3]** stretch.

---

## Shipped

### Foundations (sections 1–4, complete)

- **§1 Data sources** — [app/providers/](app/providers/): FMP, Polygon, FRED, News (Finnhub + NewsAPI fallback), Stooq, EDGAR. Shared `CacheStore` + `Throttle` + `HttpClient`. Cache warm-up via `make refresh-providers` / `make refresh-all` / `make refresh-symbol`.
- **§2 Analytics** — [app/analytics/](app/analytics/): indicators (SMA/EMA/MACD/RSI/Bollinger), risk (Sharpe/Sortino/max DD/VaR/beta/correlation), Black-Scholes (price + Greeks + IV bisection). DCF lives in `Providers::FmpService#dcf`.
- **§3 Charting** — TradingView lightweight-charts; four synchronized panes (price + SMA/Bollinger overlays, volume, RSI w/ 30-70 lines, MACD line+signal+histogram). Crosshair readout, period toggle, log-scale toggle, palette swap.
- **§4 Productivity** — search (~55 symbols, type-ahead), watchlist, price alerts UI, compare mode (rebased-to-100), CSV export.

### [PR #1](https://github.com/outten/t-money-terminal/pull/1) — operational layer

- **Portfolio (initial)** — [app/portfolio_store.rb](app/portfolio_store.rb), `/portfolio`, position widget on `/analysis/:symbol` with cost basis and live unrealized P&L. (Superseded by E in this sprint — now lot-based.)
- **Background scheduler** — [scripts/scheduler.rb](scripts/scheduler.rb) with `--tier=quotes|fundamentals|analyst|macro|alerts|all`, market-hours gate, [launchd plist example](scripts/launchd/com.tmoney.scheduler.quotes.plist).
- **Alert notifications** — [app/notifiers.rb](app/notifiers.rb) supports webhook / ntfy / SMTP. Wired into `make check-alerts`.
- **Provider health** — [app/health_registry.rb](app/health_registry.rb) (in-memory ring buffer) + `/admin/health` + `/api/admin/health.json`. Instrumented across `Providers::HttpClient` and the legacy `MarketDataService` waterfall.
- **Dividend-adjusted total return** — `:adj_close` plumbed through Yahoo / Tiingo / FMP. Sharpe / Sortino / VaR / beta now compute on adjusted closes when available; indicators stay on raw close.
- **Auto-reload dev loop** — [.rerun](.rerun) so `make run` restarts on source edits and ignores cache writes.

### [PR #2](https://github.com/outten/t-money-terminal/pull/2) — Tier 1 + CI

- **A. Dynamic symbol universe** — [app/symbol_index.rb](app/symbol_index.rb) extension store + `POST /api/symbols/discover`. Search dropdown shows a "Discover XYZ" item when the query looks like a ticker but isn't in the index.
- **B. Correlation heatmap** — `/correlations` page + `GET /api/correlations`. Server-rendered HTML table with a diverging red/white/green colormap (canvas didn't survive the parent `.chart-box` `!important` rule). Cached via `Providers::CacheStore` keyed on `(sorted symbols, period)`.
- **C. CSV export honors current chart period** — analysis-page button updates its href as the period toggle changes.
- **D. Provider degradation banner** — `HealthRegistry.degraded` surfaced on `/dashboard` with success-rate context + retry button.
- **Polygon historical fallback** — `MarketDataService.fetch_historical_from_polygon` slotted into the waterfall and `prefetch_all_historical`. Fixes symbols FMP paywalls (CMCSA, BRK.B, smaller-caps) for users with a Polygon key.
- **GitHub Actions CI** — [.github/workflows/ci.yml](.github/workflows/ci.yml) runs RSpec + scripts syntax check on every PR. `.ruby-version` pinned to 3.4.1.

### This sprint — Tier 2 portfolio cluster (E + F)

- **E. Tax lots / lot-based portfolio** — [app/portfolio_store.rb](app/portfolio_store.rb) refactored to multi-lot. Each lot keeps its own cost basis and acquired_at; `find(symbol)` aggregates with weighted-avg cost basis. Closed lots are retained for audit (`closed_at` + realized P&L recorded inline). Backward-compatible migration backfills new fields on legacy rows.
- **F. Realized P&L / trade history** — [app/trades_store.rb](app/trades_store.rb) (append-only `data/trades.json`). `close_shares_fifo` walks open lots oldest-first, splits the last lot if partially closed, records the breakdown. New `/trades` page + `GET /api/trades`. New routes: `POST /api/portfolio/buy`, `POST /api/portfolio/sell`, `DELETE /api/lots/:id`. `/portfolio` summary cards now include **Realized P&L (YTD)** alongside unrealized.
- **UI** — [views/portfolio.erb](views/portfolio.erb) shows aggregated rows with expandable per-lot detail and an inline FIFO sell form. `/analysis/:symbol` Position widget got a `<details>` lot breakdown + sell form + "Buy more (new lot)" button.

**Tests:** 224 examples, 0 failures (+14 new lot/FIFO/trades coverage in [spec/feature_spec.rb](spec/feature_spec.rb)).

---

## Open work — prioritized plan

### Tier 2 — high value, medium cost (remaining)

#### G. Dashboard concurrent fetch [P2]
- **Problem**: dashboard makes serial provider calls on cache miss — quote fan-out + macro + indices + earnings + watchlist quotes. First hit can be slow.
- **Plan**: wrap the independent sections in `Thread.new`; rejoin before render. Each `safe_fetch` block is already isolated. Bound max threads to ~8 to avoid bursting any single provider.
- **Touches**: dashboard route in [app/main.rb](app/main.rb).
- **Cost**: 1 day.

#### H. Backtest framework — single-strategy MVP [P2]
- **Problem**: for a "research tool," the most natural question — *"what would this strategy have done?"* — has no answer.
- **Plan**: pure-Ruby walk-forward simulator that takes a buy/sell rule and a cached historical series, returns equity curve + ann. return + max DD + Sharpe. Start with one demo: RSI mean-reversion on SPY (`buy < 30`, `sell > 70`). Render equity curve + buy-and-hold comparison.
- **Cost**: 2 days.

### Tier 3 — eventually, lower urgency

#### I. News sentiment scoring [P2]
- Lightweight per-headline score (VADER-style or keyword weighted), no LLM/API cost. Aggregate to a bullish/bearish gauge on `/analysis/:symbol`.
- Pure Ruby in [app/analytics/](app/analytics/). 1 day.

#### J. MarketDataService refactor [P2 — was P1]
- ~1,200-LOC file. Split per-provider modules along the [app/providers/](app/providers/) pattern. Pure tech debt — only do this if a feature forces the issue. 1–2 days.

#### K. Efficient frontier [P3]
- Markowitz mean-variance optimization across the portfolio (now natively multi-lot, so we can compute weights from `PortfolioStore.positions`). Builds on `Analytics::Risk.correlation` + `PortfolioStore`. Academic interpretation cautions apply. 1–2 days.

#### L. Sector treemap [P3]
- Treemap with sector-weighted color = % change. Needs sector classification (FMP `/profile`) and a new JS dep (d3 or echarts). Aesthetic value mostly. 1 day.

#### M. Pre-fetch historicals on discovery [P2 — newly visible]
- **Problem**: when a user discovers a ticker via the search dropdown, only the quote is fetched. The first `/analysis/:symbol` visit then re-races the historical providers, which can fail (CMCSA case) and leave a blank chart.
- **Plan**: fire-and-forget thread in `POST /api/symbols/discover` that calls `MarketDataService.historical(symbol, '1y')`. By the time the user navigates, the cache is warm. Best-effort — doesn't fail discovery on historical failure.
- **Cost**: half a day.

#### N. Richer empty-state when historicals fail [P2 — newly visible]
- **Problem**: when every provider is rate-limited or paywalled, the chart shows a generic "No historical data available" message. The CMCSA investigation surfaced that users have no way to know *why*.
- **Plan**: when `@historical` is empty, render a panel showing each tried provider with its last status (from `HealthRegistry`), explain that a refresh now will hit the same gates, and suggest waiting for cooldowns or scheduling a fetch via the scheduler.
- **Cost**: half a day.

---

## Dropped

Items removed from the roadmap. Recorded here so the choice is visible:

- **§2.4 Monte Carlo simulation** — GBM fan charts have thin tails, no regime modelling. Looks impressive, financially misleading. Skip.
- **§3.7 Options visualizations** — Polygon free tier is end-of-day only, which makes any options UX stale. Revisit only if a paid data source is in scope.
- **§1.7 CoinGecko crypto** — out of scope unless the user explicitly wants crypto.
- **§1.5 Alpha Vantage technical indicators** — local compute (§2.1, shipped) is the right answer; AV is a 25-req/day budget that's better spent on quote fallbacks.
- **§5.3 expanded test coverage as a standalone task** — happens organically alongside features; not a planning unit.

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

# Alert delivery (optional — pick any one)
ALERT_WEBHOOK_URL=...    # POST JSON
ALERT_NTFY_TOPIC=...     # ntfy.sh topic
ALERT_EMAIL_TO=...       # plus ALERT_SMTP_HOST / USER / PASS / FROM
```
