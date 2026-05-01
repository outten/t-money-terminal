# TODO — T Money Terminal Roadmap

**Scope constraints**
- Free APIs only. Rate limits absorbed in code (caching + throttling — see [app/market_data_service.rb](app/market_data_service.rb), [app/providers/cache_store.rb](app/providers/cache_store.rb)).
- New data categories get their own `data/cache/<namespace>/` subdirectory.
- Single-user, file-backed state under `data/`. Multi-user rebuild = SQLite, out of scope.
- **Page renders must never fire providers** — broker imports + scheduler + first-view `/analysis/:symbol` are the only network events. See `MarketDataService.quote_cached` and the cache-only contract in [README.md](README.md).

**Legend** — **[P0]** core value · **[P1]** high ROI · **[P2]** nice-to-have · **[P3]** stretch.

---

## Shipped

### Foundations (sections 1–4 of the original spec, complete)

- **§1 Data sources** — [app/providers/](app/providers/): FMP, Polygon, FRED, News (Finnhub + NewsAPI fallback), Stooq, EDGAR. Shared `CacheStore` + `Throttle` + `HttpClient`.
- **§2 Analytics** — [app/analytics/](app/analytics/): indicators, risk (Sharpe/Sortino/max DD/VaR/beta/correlation), Black-Scholes (price + Greeks + IV).
- **§3 Charting** — TradingView lightweight-charts; four equal-height synchronized panes (price + SMA/Bollinger, volume, RSI, MACD).
- **§4 Productivity** — search, watchlist, price alerts UI, compare mode, CSV export.

### [PR #1](https://github.com/outten/t-money-terminal/pull/1) — operational layer
- Initial portfolio (single-position-per-symbol, superseded by multi-lot in PR #3).
- Background scheduler ([scripts/scheduler.rb](scripts/scheduler.rb), `--tier=quotes|fundamentals|analyst|macro|alerts|all`).
- Alert notifications ([app/notifiers.rb](app/notifiers.rb): webhook / ntfy / SMTP).
- Provider health ([app/health_registry.rb](app/health_registry.rb)) + `/admin/health`.
- Dividend-adjusted total return — `:adj_close` plumbed through Yahoo / Tiingo / FMP.
- Auto-reload dev loop ([.rerun](.rerun)).

### [PR #2](https://github.com/outten/t-money-terminal/pull/2) — Tier 1 + CI
- **A. Dynamic symbol universe** — extension store + `POST /api/symbols/discover`, search-dropdown auto-discovery.
- **B. Correlation heatmap** — `/correlations` page + `GET /api/correlations`, server-rendered HTML table with diverging colormap.
- **C. CSV export honors current chart period** — analysis-page button updates href as the period toggle changes.
- **D. Provider degradation banner** — `HealthRegistry.degraded` surfaced on `/dashboard`.
- **Polygon historical fallback** wired into `MarketDataService` (fixes CMCSA / FMP-paywalled symbols).
- **GitHub Actions CI** — [.github/workflows/ci.yml](.github/workflows/ci.yml) runs RSpec + scripts syntax check on every PR.

### [PR #3](https://github.com/outten/t-money-terminal/pull/3) — Tier 2 portfolio cluster (E + F)
- **E. Tax lots** — [app/portfolio_store.rb](app/portfolio_store.rb) refactored to multi-lot; closed lots retained inline for audit.
- **F. Realized P&L / trade history** — [app/trades_store.rb](app/trades_store.rb), `/trades` page, FIFO `close_shares_fifo` with per-lot breakdown.

### [PR #4](https://github.com/outten/t-money-terminal/pull/4) — Fidelity broker import + cache sync
- [app/fidelity_importer.rb](app/fidelity_importer.rb) — parses `Portfolio_Positions_*.csv`; replaces lots; primes quote cache; writes [import snapshot](app/import_snapshot_store.rb).
- `/portfolio/import/fidelity` POST + UI button + result banner.
- Bust historical cache for imported symbols on re-import.

### [PR #5](https://github.com/outten/t-money-terminal/pull/5) — Drift + market-aware caching + snapshot fallback
- **Drift view** at `/portfolio/drift` ([app/portfolio_diff.rb](app/portfolio_diff.rb)) — what changed between two snapshots.
- **Market-aware TTL** — 1 h during market hours, 12 h closed.
- **Snapshot fallback in `fetch_quote`** — broker import is the last resort before MOCK_PRICES when providers fail.

### [PR #6](https://github.com/outten/t-money-terminal/pull/6) — `/portfolio` cache-only after import
- `load_from_disk` populates `@cache` (live), not just `@persistent_cache` — quotes survive process restart.
- `MarketDataService.analyst_cached` (network-free read) + `cached_only:` kwarg on `RecommendationService.signal_for` — `/portfolio` no longer fans out N Finnhub calls per render.

### [PR #7](https://github.com/outten/t-money-terminal/pull/7) — Pre-fetch historicals on import (TODO M, shipped)
- [app/historical_prefetcher.rb](app/historical_prefetcher.rb) — fire-and-forget thread populates 1y bars for every imported symbol so the first `/analysis/:symbol` click renders instantly.

### [PR #8](https://github.com/outten/t-money-terminal/pull/8) — Strict cache-only render
- New `MarketDataService.quote_cached` — TTL-bypassing read; layered fallback (`@cache → @persistent_cache → snapshot → nil`). `valuate_position` uses it. Page renders never call `fetch_quote`.

### [PR #9](https://github.com/outten/t-money-terminal/pull/9) — refresh-all expansion + FMP paywall + admin refresh
- [app/refresh_universe.rb](app/refresh_universe.rb) — single source of truth for the symbol set; `make refresh-all` now covers REGIONS ∪ portfolio ∪ watchlist (~528 symbols for the user's portfolio) instead of 15.
- **FMP paywall tombstone** — on HTTP 402 we write a 24 h tombstone at `data/cache/fmp/_paywalled_/<SYM>.txt` and short-circuit future requests; HealthRegistry success rate stops degrading from compounding 402s.
- **Admin refresh buttons** — `/admin/cache` action bar (refresh one symbol synchronously, refresh ALL in a background thread, per-row ↻ buttons), live progress banner, `RefreshTracker` for in-memory job state.

### [PR #10] — Tax-aware sells + benchmark comparison
- **Tax-lot classification** ([app/tax_lot.rb](app/tax_lot.rb)) — every closed lot tagged short-term (held ≤ 1 yr) or long-term (held > 1 yr). For Fidelity-imported lots without an explicit acquisition date, falls back to the earliest broker snapshot containing the symbol with sufficient shares.
- **Wash-sale flagging** ([app/wash_sale.rb](app/wash_sale.rb)) — SELLs at a loss are scanned for same-symbol BUYs within ±30 days. Flags persist on the trade record with the recommended resume date. Warning banner on `/trades` for each affected sell.
- **Benchmark comparison** ([app/analytics/benchmark.rb](app/analytics/benchmark.rb)) — `/portfolio` shows your lot-weighted return-since-acquired vs SPY return over the same window, plus alpha. Pure cache-only computation.
- **Sell preview** — `POST /api/portfolio/sell/preview` returns the breakdown (short/long P&L + wash-sale flags) without committing.
- `/portfolio` summary cards split realized YTD by short vs long. `/trades` page shows holding-period badges + wash-sale warnings inline.
- 22 new tests in [spec/tax_lot_spec.rb](spec/tax_lot_spec.rb).

### [PR #12] — Portfolio value-over-time chart + per-position sparklines + Fidelity backfill
- **PortfolioHistory** ([app/portfolio_history.rb](app/portfolio_history.rb)) — pivots `ImportSnapshotStore` snapshots into a total time series (date / total_value / total_cost / unrealized_pl / day-over-day delta) and a per-symbol time series for sparklines. Inline-SVG sparkline renderer (no JS dependency, green/red by direction).
- **Value-over-time chart** at the top of `/portfolio` — Chart.js line chart of total portfolio value across every Fidelity snapshot, with hover tooltip showing date + total + Δ vs prior + unrealized P&L. Three summary cards (latest value, day-over-day change, unrealized P&L). Hidden until 2+ snapshots exist; single-snapshot empty state when only one.
- **Trend column** on the positions table — inline-SVG sparkline per symbol with hover-tooltip carrying snapshot count + date range + total $/% change.
- **`FidelityImporter.backfill_snapshots!`** — snapshots every Fidelity CSV that doesn't yet have a JSON snapshot, scanning BOTH `data/porfolio/fidelity/` (canonical input) AND `data/imports/fidelity/` (output dir, in case CSVs got dropped there by mistake). Does NOT touch PortfolioStore, the quote cache, or trigger historical prefetch — purely additive snapshot creation. Idempotent.
- **Backfill button** on `/portfolio` (with pending-CSV count) + POST `/portfolio/import/fidelity/backfill` route + `GET /api/portfolio/history` JSON peer.
- 24 new tests in [spec/portfolio_history_spec.rb](spec/portfolio_history_spec.rb).

**Tests:** 427 examples, 0 failures across 16 spec files.

### [PR #11] — Tax-loss harvesting sub-page
- **ProfileStore** ([app/profile_store.rb](app/profile_store.rb)) — single-user investment profile at `data/profile.json`. Fields: `current_age`, `retirement_age`, `risk_tolerance` (aggressive/moderate/conservative), `federal_ltcg_rate`, `federal_ordinary_rate`, optional `state_tax_rate`, `niit_applies`. Range-validated; mutex + atomic write.
- **TaxHarvester** ([app/tax_harvester.rb](app/tax_harvester.rb)) — analysis engine that ranks open underwater lots by estimated tax savings (loss × marginal rate, ST = ordinary, LT = LTCG, +state +NIIT if configured), detects lots crossing ST→LT in ≤ 30 days, summarises YTD realised against the $3 k ordinary-offset cap, and emits per-candidate `harvest` / `wait` / `skip` recommendations branched on risk tolerance, holding period, days-to-LT, and wash-sale risk.
- **Replacement-security map** — heuristic different-INDEX swaps to dodge the wash-sale rule (SPY → VTI, QQQ → VUG/SCHG, SCHD → VYM/HDV, etc.). Same-INDEX trios (SPY ↔ VOO ↔ IVV) are intentionally NOT recommended as replacements.
- **`/portfolio/tax-harvest` page** ([views/tax_harvest.erb](views/tax_harvest.erb)) — profile summary (5 cards), inline profile config form, YTD realised summary with $3 k cap progress, ST→LT crossing watchlist, ranked candidates table with recommendation + reason + wash flag + replacement links, and a prominent "decision support, not tax advice" disclaimer.
- **Routes**: `GET /portfolio/tax-harvest` (HTML), `GET /api/portfolio/tax-harvest` (JSON), `POST /profile` (form), `POST /api/profile` (JSON). Cache-only — no provider fan-out on render.
- 42 new tests in [spec/tax_harvest_spec.rb](spec/tax_harvest_spec.rb) (ProfileStore validation/persistence + TaxHarvester candidate/threshold/YTD math + route-render smoke + form/JSON profile updates).

**Tests:** 403 examples, 0 failures across 15 spec files. (Superseded by PR #12 — see above.)

---

## Open work — prioritized plan

### Tier 2 — high value, medium cost (remaining)

#### G. Dashboard concurrent fetch [P2]
- **Problem**: dashboard makes serial provider calls on cache miss (quote fan-out + macro + indices + earnings + watchlist quotes). First hit can be slow.
- **Plan**: wrap independent sections in `Thread.new`; rejoin before render. Each `safe_fetch` block is already isolated. Bound max threads to ~8.
- **Touches**: dashboard route in [app/main.rb](app/main.rb).
- **Cost**: 1 day.

#### H. Backtest framework — single-strategy MVP [P2]
- **Problem**: for a "research tool," *"what would this strategy have done?"* has no answer.
- **Plan**: pure-Ruby walk-forward simulator that takes a buy/sell rule + cached historical series → returns equity curve + ann. return + max DD + Sharpe. Demo: RSI mean-reversion on SPY (`buy < 30`, `sell > 70`). Render equity curve + buy-and-hold comparison.
- **Cost**: 2 days.

### Tier 3 — eventually, lower urgency

#### I. News sentiment scoring [P2]
- Lightweight per-headline score (VADER-style or keyword-weighted), no LLM/API cost. Aggregate to a bullish/bearish gauge on `/analysis/:symbol` and a notes column on `/portfolio`.
- Pure Ruby in [app/analytics/](app/analytics/). 1 day.

#### J. MarketDataService refactor [P2 — was P1]
- ~1,400-LOC file. Split per-provider modules along the [app/providers/](app/providers/) pattern. Pure tech debt — only do this if a feature forces the issue. 1–2 days.

#### K. Efficient frontier [P3]
- Markowitz mean-variance optimization across the portfolio (now natively multi-lot, so weights come from `PortfolioStore.positions`). Builds on `Analytics::Risk.correlation`. 1–2 days.

#### L. Sector treemap [P3]
- Treemap with sector-weighted color = % change. Needs sector classification (FMP `/profile`) and a new JS dep (d3 or echarts). Aesthetic. 1 day.

#### N. Richer empty-state when historicals fail [P2 — newly visible]
- **Problem**: when every provider is rate-limited or paywalled, the chart shows a generic "No historical data available" message; users have no way to know *why*.
- **Plan**: when `@historical` is empty, render a panel showing each tried provider with its last status (from `HealthRegistry`); suggest waiting for cooldowns or scheduling a fetch.
- **Cost**: half a day.

#### O. Multi-broker importer [P3 — newly visible]
- **Problem**: the Fidelity importer is tightly coupled to Fidelity's CSV shape. Schwab / Robinhood / Vanguard need their own parsers.
- **Plan**: extract a `BrokerImporter` interface; refactor `FidelityImporter` to implement it; add per-broker parsers as we need them. The snapshot store + cache sync are already source-keyed (`ImportSnapshotStore.write(source: ...)`).
- **Cost**: 1 day per additional broker.

#### P. EDGAR filings panel on /analysis [P3]
- Wire `Providers::EdgarService.recent_filings` (already implemented) into `/analysis/:symbol`. Needs a ticker→CIK mapping (SEC publishes one). Refresh on import.
- **Cost**: 1 day.

---

## Dropped

Recorded so the choice is visible:

- **Monte Carlo simulation** — GBM fan charts have thin tails, no regime modelling. Looks impressive, financially misleading.
- **Options visualizations** — Polygon free tier is end-of-day only, makes any options UX stale.
- **CoinGecko crypto** — out of scope unless explicitly wanted.
- **Alpha Vantage technical indicators** — local compute is the right answer; AV's 25 req/day budget is better spent on quote fallbacks.
- **§5.3 expanded test coverage as a standalone task** — happens organically with features.

Items also resolved through the work in PRs #4–#9:
- **§5.4 provider health dashboard** → `/admin/health` (PR #1)
- **§4.5 CSV honor period** → C in PR #2
- **§3.6 correlation heatmap** → B in PR #2
- **§1.8 EDGAR (thin)** → already implemented; consumer panel still pending (item P above)

---

## API signup checklist

See [CREDENTIALS.md](CREDENTIALS.md) for the full setup walkthrough including the FMP free-tier paywall behaviour and alert-delivery options.

```
# Core market data
TIINGO_API_KEY=...
ALPHA_VANTAGE_API_KEY=...
FINNHUB_API_KEY=...

# Deeper data
FMP_API_KEY=...          # 250/day; per-symbol whitelist (see CREDENTIALS.md)
POLYGON_API_KEY=...      # 5/min
FRED_API_KEY=...         # unlimited
NEWSAPI_KEY=...          # 100/day; optional Finnhub fallback

# Alert delivery (optional)
ALERT_WEBHOOK_URL=...
ALERT_NTFY_TOPIC=...
ALERT_EMAIL_TO=...       # plus ALERT_SMTP_HOST / USER / PASS / FROM
```
