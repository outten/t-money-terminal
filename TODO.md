# TODO — T Money Terminal Roadmap

**Scope constraints**
- Free APIs only. Rate limits are absorbed by code (caching + throttling — see [app/market_data_service.rb](app/market_data_service.rb), [app/providers/cache_store.rb](app/providers/cache_store.rb)).
- New data categories get their own `data/cache/<namespace>/` subdirectory.
- Single-user, file-backed state (`data/portfolio.json`, `data/watchlist.json`, `data/alerts.json`). A multi-user rebuild moves to SQLite — out of scope.

**Legend** — **[P0]** core value · **[P1]** high ROI · **[P2]** nice-to-have · **[P3]** stretch.

---

## Shipped

### Foundations (sections 1–4, complete)

- **§1 Data sources** — [app/providers/](app/providers/): FMP, Polygon, FRED, News (Finnhub + NewsAPI fallback), Stooq, EDGAR. Shared `CacheStore` + `Throttle` + `HttpClient`. Cache warm-up via `make refresh-providers` / `make refresh-all` / `make refresh-symbol`.
- **§2 Analytics** — [app/analytics/](app/analytics/): indicators (SMA/EMA/MACD/RSI/Bollinger), risk (Sharpe/Sortino/max DD/VaR/beta/correlation), Black-Scholes (price + Greeks + IV bisection). DCF lives in `Providers::FmpService#dcf`.
- **§3 Charting** — TradingView lightweight-charts; four synchronized panes (price + SMA/Bollinger overlays, volume, RSI w/ 30-70 lines, MACD line+signal+histogram). Crosshair readout, period toggle, log-scale toggle, palette swap.
- **§4 Productivity** — search (~55 symbols, type-ahead), watchlist, price alerts UI, compare mode (rebased-to-100), CSV export.

### Recently merged ([PR #1](https://github.com/outten/t-money-terminal/pull/1))

- **Portfolio** — [app/portfolio_store.rb](app/portfolio_store.rb), `/portfolio`, position widget on `/analysis/:symbol` with cost basis and live unrealized P&L.
- **Background scheduler** — [scripts/scheduler.rb](scripts/scheduler.rb) with `--tier=quotes|fundamentals|analyst|macro|alerts|all`, market-hours gate, [launchd plist example](scripts/launchd/com.tmoney.scheduler.quotes.plist).
- **Alert notifications** — [app/notifiers.rb](app/notifiers.rb) supports webhook / ntfy / SMTP. Wired into `make check-alerts`.
- **Provider health** — [app/health_registry.rb](app/health_registry.rb) (in-memory ring buffer) + `/admin/health` + `/api/admin/health.json`. Instrumented across `Providers::HttpClient` and the legacy `MarketDataService` waterfall.
- **Dividend-adjusted total return** — `:adj_close` plumbed through Yahoo / Tiingo / FMP. Sharpe / Sortino / VaR / beta now compute on adjusted closes when available; indicators stay on raw close.
- **Auto-reload dev loop** — [.rerun](.rerun) so `make run` restarts on source edits and ignores cache writes.

**Tests:** 158 examples, 0 failures.

---

## Open work — prioritized plan

### Tier 1 — high value, low cost (do these first)

#### A. Dynamic symbol universe [P0]
- **Problem**: app is hard-capped to ~55 curated tickers. Searching anything else fails silently. Single biggest visible limitation.
- **Plan**: when a search query has no `SymbolIndex` match, hit `MarketDataService.quote(query)` once. If a quote comes back, append to a runtime extension of `SymbolIndex` and persist to `data/symbols_extended.json` so it survives restarts. Add `name` lookup via `Providers::FmpService.profile` or Finnhub profile.
- **Touches**: [app/symbol_index.rb](app/symbol_index.rb), `/api/symbols`, `VALID_SYMBOLS` callsites.
- **Cost**: 1 day.

#### B. Correlation heatmap [P1]
- **Problem**: `Analytics::Risk.correlation` exists but isn't surfaced. Watchlist is a stack of independent rows; pairwise correlation is the most useful comparison view.
- **Plan**: new `/correlations` page (or tab on `/compare`). `GET /api/correlations?symbols=…&period=1y` returns an N×N matrix. Render with a plain `<canvas>` (no new JS dep). Reuse the period toggle.
- **Touches**: new view, new route, no new analytics code.
- **Cost**: half a day.

#### C. CSV export honors current chart period [P3]
- **Problem**: button on `/analysis/:symbol` pins to `1y`. Should match the chart's active period.
- **Plan**: read the period state from `historicalChartState`, append `?period=…` to the export URL, server side already supports every period.
- **Cost**: 30 minutes.

#### D. Surface provider degradation on the dashboard [P1]
- **Problem**: `/admin/health` exists but nothing prompts the user to check it. If quotes are 429ing across the board, the user just sees stale data with no warning.
- **Plan**: add a top-banner on the dashboard when any provider's success rate over the last 20 calls drops below 50%. One link to `/admin/health` and one to refresh.
- **Touches**: [views/dashboard.erb](views/dashboard.erb), small helper in [app/main.rb](app/main.rb).
- **Cost**: half a day.

### Tier 2 — high value, medium cost

#### E. Tax lots / lot-based portfolio [P1]
- **Problem**: `PortfolioStore` allows one entry per symbol. Real investors buy AAPL in March, June, October — each lot has its own basis and holding period.
- **Plan**: lot table — `{id, symbol, shares, cost_basis, acquired_at}`. Aggregated views (`/portfolio`, position widget) sum across lots and report **average cost** + **per-lot detail (expandable)**. FIFO matching gets bolted on with realized P&L (item F).
- **Touches**: [app/portfolio_store.rb](app/portfolio_store.rb) becomes lot-aware; views show aggregated + drill-down.
- **Cost**: 1–2 days.

#### F. Realized P&L / trade history [P1]
- **Problem**: when the user sells, P&L disappears. No record of "what did I actually make this year?"
- **Plan**: a `/trades` page backed by `data/trades.json`. Adding a SELL closes lots FIFO, computes realized P&L, writes a trade record `{date, symbol, side, shares, price, realized_pl, lots_closed}`. Year-to-date totals on the dashboard.
- **Depends on**: E (lot-based portfolio).
- **Cost**: 1–2 days.

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
- 1,200-LOC file. Split per-provider modules along the [app/providers/](app/providers/) pattern. Pure tech debt — only do this if a feature forces the issue. 1–2 days.

#### K. Efficient frontier (was §2.6) [P3]
- Markowitz mean-variance optimization across portfolio holdings. Builds on `Analytics::Risk.correlation` + `PortfolioStore`. Academic interpretation cautions apply. 1–2 days.

#### L. Sector treemap (was §3.5) [P3]
- Treemap with sector-weighted color = % change. Needs sector classification (FMP `/profile`) and a new JS dep (d3 or echarts). Aesthetic value mostly. 1 day.

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
