# T Money Terminal

A self-hosted, open-source investment terminal inspired by the Bloomberg Terminal — Ruby + Sinatra, powered entirely by **free-tier APIs**. The contract: **the broker import is the only refresh event**, page renders are read-only against an aggressive on-disk cache. Pages stay fast even when upstreams throttle, paywall, or fail entirely.

---

## What it does

### Market data — provider waterfall, free tier

Every quote / historical fetch tries each provider in order and falls back on failure or rate-limit. With your keys set, your IP is throttle-resilient against any single source.

| Layer | Order | Notes |
|---|---|---|
| **Quotes** | Tiingo → Alpha Vantage → Finnhub → Yahoo | First non-empty wins; rate-limit cooldowns are observed per-provider |
| **Historical OHLCV** | Yahoo → FMP → **Polygon** → Finnhub → Tiingo → AV-weekly | Polygon was added because FMP free tier paywalls per-symbol; covers ADRs and small-caps Yahoo throttles |
| **Analyst consensus** | Finnhub | Cached aggressively (`/portfolio` reads cache-only) |
| **Company profiles** | Finnhub for stocks; hardcoded `ETF_PROFILES` for SPY/QQQ/EWJ/VGK | |

### Deeper data ([app/providers/](app/providers/))

| Provider | Used for | Free tier |
|---|---|---|
| Financial Modeling Prep (FMP) | Key ratios, DCF, earnings calendar, key metrics, historical fallback | 250/day; **per-symbol whitelist** — see CREDENTIALS.md |
| Polygon.io | Daily aggregates, options chains, IV, open interest | 5/min |
| FRED | Fed funds, 3M/10Y treasury, CPI, unemployment, VIX | unlimited |
| Finnhub News + NewsAPI | Per-symbol headlines | 60/min and 100/day |
| Stooq | Nikkei, Hang Seng, DAX, FTSE, CAC, S&P 500, Nasdaq, Dow | none required |
| SEC EDGAR | Latest 10-K / 10-Q / 8-K filings | none required (UA header) — currently wired but no view consumes it |

### Pure-Ruby analytics ([app/analytics/](app/analytics/))

Zero API cost — runs off cached bars.

- [indicators.rb](app/analytics/indicators.rb) — SMA, EMA, MACD, RSI (Wilder), Bollinger Bands
- [risk.rb](app/analytics/risk.rb) — annualized return + vol, Sharpe, Sortino, max drawdown, historical + parametric VaR, beta, **correlation matrix**, date alignment (uses dividend-adjusted close when available)
- [black_scholes.rb](app/analytics/black_scholes.rb) — European price, full Greeks (Δ/Γ/Vega/Θ/ρ), implied vol (bisection), historical vol

### Charting

TradingView [lightweight-charts](https://www.tradingview.com/lightweight-charts/) (CDN, MIT) — four equal-height synchronized panes (price + SMA 20/50/200 + Bollinger, volume coloured by candle direction, RSI(14) with 30/70 reference lines, MACD(12/26/9) line + signal + histogram). Crosshair OHLCV readout, period toggle (1d / 1m / 3m / YTD / 1y / 5y), log-scale toggle, dark-mode palette swap.

### Portfolio (multi-lot, FIFO, tax-aware)

- [PortfolioStore](app/portfolio_store.rb) — every BUY creates a new lot with its own cost basis and acquired_at; aggregated views sum across lots with weighted-average cost and a per-lot drill-down
- **FIFO close** on SELL — `close_shares_fifo` walks open lots oldest-first, splits the last one if partially closed, returns the realized-P&L breakdown per closed lot
- **Tax-lot classification** — every closed lot is tagged short-term (held ≤ 1 yr) or long-term (held > 1 yr); `/portfolio` and `/trades` split realized P&L YTD by holding period (always visible, even with no sells yet). Each open lot's expandable detail also shows **"Tax (if sold today)"** with current holding period + days-to-long-term countdown for short-term lots. For Fidelity-imported lots without an explicit acquisition date, [TaxLot](app/tax_lot.rb) falls back to the earliest broker snapshot containing the symbol.
- **Wash-sale flagging** — SELLs at a loss are scanned for same-symbol BUYs within ±30 days; flags persist on the trade record with the recommended resume date and surface inline on `/trades`. See [WashSale](app/wash_sale.rb). Same-symbol matching only — "substantially identical" mutual funds / options are out of scope.
- **Benchmark comparison** — `/portfolio` shows your lot-weighted return-since-acquired vs SPY return over the same window, plus alpha. Pure cache-only computation via [Analytics::Benchmark](app/analytics/benchmark.rb).
- [TradesStore](app/trades_store.rb) — append-only history at `data/trades.json`; YTD + lifetime realized-P&L cards split by short-term / long-term.
- **Drift view** at `/portfolio/drift` — what changed between your two most recent broker imports (added / removed / scaled, sorted biggest-mover-first)
- **Sell preview** — `POST /api/portfolio/sell/preview` returns the breakdown (short/long P&L + wash-sale flags) without committing.
- **Value over time + per-position sparklines** ([PortfolioHistory](app/portfolio_history.rb)) — `/portfolio` renders a Chart.js line chart of total portfolio value across every Fidelity snapshot, with day-over-day delta in the tooltip; the positions table gains a Trend column with an inline-SVG sparkline per symbol (green if last ≥ first, red otherwise). One snapshot = one data point, so the X axis is "import dates" not calendar days. **Backfill button** on `/portfolio` snapshots every Fidelity CSV that doesn't yet have a JSON snapshot — without touching PortfolioStore, the quote cache, or kicking off historical prefetch — so dropped historical CSVs become history without disturbing current state. Cache-only render.
- **Performance leaders & laggards** — `/portfolio` ranks the top 5 gainers and top 5 laggards across the snapshot window by **per-share price change** (not market-value change, which would conflate price action with the user's own buys/sells). Filters out positions whose share count drifted >5% between first and last snapshot — catches stock splits, big buys, and broker data quirks. Each row carries a 60×18 sparkline.
- **Asset-class breakdown** ([AssetClassMapper](app/asset_class_mapper.rb)) — `/portfolio` classifies the latest snapshot's positions into US stocks / international stocks / target-date / bonds / balanced / real estate / commodities / cash / unmapped, with $ + %-of-portfolio and the top 3 holdings per class. Classification uses a hand-curated symbol map plus description-text heuristics (FIDELITY FREEDOM 2035 → target-date, ADS EA REP → international, etc.). The map covers ~96% of a real ~$2M Fidelity portfolio out of the box; the unmapped bucket is honestly reported so coverage gaps are visible.
- **Tax-loss harvesting** at `/portfolio/tax-harvest` — open lots underwater are ranked by estimated tax savings (loss × your federal short-/long-term rate, plus optional state + NIIT), with per-candidate `harvest` / `wait` / `skip` recommendations branched on risk tolerance, the ST→LT crossing window, and wash-sale risk. Each candidate also carries an **Underwater streak** (snapshots-since-red and calendar days, derived from `PortfolioHistory.underwater_streak`) so noise (red 3 days) is visibly distinct from conviction (red 60+ days). Includes a YTD realised summary with $3 k ordinary-offset cap progress, a "lots crossing ST→LT in ≤ 30 days" watchlist, and heuristic different-INDEX replacement-security suggestions (e.g. SPY → VTI, QQQ → VUG). Configurable user profile (current age, retirement age, risk tolerance, marginal rates, NIIT, retirement target value) lives in [ProfileStore](app/profile_store.rb) at `data/profile.json`. See [TaxHarvester](app/tax_harvester.rb).
- **Retirement progress** ([RetirementProjection](app/retirement_projection.rb)) — when both ages and `retirement_target_value` are set in your profile, `/portfolio` renders a "Retirement progress" section showing years remaining, current value, target, gap, and the **required compound annual return** to hit the target by retirement age. Includes a **caveated verdict** (`On track` / `Tight` / `Not on track`) anchored to long-run nominal CAGRs from cited sources (NYU Stern Damodaran 1928–2023 dataset; Bogleheads historical returns wiki) so you can sanity-check whether the required return is realistic against historical equity / bond / 60-40 norms. Citations open in a new tab.

### Broker import (Fidelity)

Drop a `Portfolio_Positions_<Mmm>-<DD>-<YYYY>.csv` in `data/porfolio/fidelity/` (Fidelity's typo, kept), click **Import latest Fidelity export** on `/portfolio`, and:

1. Lots in PortfolioStore are replaced with the broker's per-symbol average cost basis (manual entries for symbols *not* in the file are preserved)
2. Unknown tickers register as `SymbolIndex` extensions so `/analysis/:symbol` resolves
3. Quote cache is primed from the file's Last Price (page renders without firing providers)
4. Historical cache is busted for affected symbols and re-fetched in a **background thread** so `/analysis/:symbol` is instant on first click
5. The full parsed payload is persisted as a snapshot at `data/imports/fidelity/<basename>.json` for audit + drift comparison

### Productivity

- **Universal search** — type-ahead over the curated universe, auto-discovery for unknown tickers (`POST /api/symbols/discover` adds them as extensions)
- **Watchlist** — server-persisted to `data/watchlist.json`; live quotes on dashboard + ☆/★ toggle on `/analysis/:symbol`
- **Price alerts** — threshold alerts at `data/alerts.json`; `make check-alerts` evaluates and dispatches via configured Notifiers (webhook, ntfy.sh, SMTP)
- **Compare mode** — `/compare?symbols=AAPL,MSFT,GOOGL&period=1y`, rebased to 100 (≤ 6 symbols)
- **Correlation heatmap** — `/correlations` page; HTML-table render with diverging red/white/green colormap
- **CSV export** — `/api/export/:symbol/:period.csv` returns OHLCV + every indicator series for the chart's currently-displayed period

### Caching contract

The cache is the source of truth for page rendering:

- `MarketDataService.quote_cached(symbol)` — strict TTL-bypassing read used by `/portfolio`. Layered fallback: `@cache → @persistent_cache → broker snapshot → nil`. Never fires a provider call on render.
- **Market-aware TTL** — 1 h during US market hours (M–F 09:30–16:00 ET), **12 h** when closed. A Friday-close prime stays valid all weekend.
- **FMP paywall tombstone** — on HTTP 402 we write a 24 h tombstone at `data/cache/fmp/_paywalled_/<SYM>.txt`; future requests for that symbol short-circuit before HTTP. Re-tested daily.
- **`load_from_disk`** seeds both `@cache` and `@persistent_cache`, so quotes survive process restarts (rerun reload, Puma recycle).

The only network events are: explicit imports, the scheduler (`make scheduler`), the `/admin/refresh/*` buttons, and first-view `/analysis/:symbol` for symbols not yet in cache. **Page renders never fan out.**

---

## Pages

| Page | URL |
|---|---|
| Dashboard (regions + macro + intl. indices + watchlist + upcoming earnings + provider-degradation banner) | `/dashboard` |
| Region (US / Japan / Europe) | `/region/us`, `/region/japan`, `/region/europe` |
| Per-symbol analysis (fundamentals, DCF, news, candles, analytics, position widget, alerts) | `/analysis/:symbol` |
| Portfolio (multi-lot, signals, notes, broker import) | `/portfolio` |
| Trade history (BUY/SELL log + realized P&L YTD / lifetime) | `/trades` |
| Portfolio drift (snapshot diff) | `/portfolio/drift` |
| Tax-loss harvesting (loss-ranked candidates, ST→LT watchlist, replacement suggestions) | `/portfolio/tax-harvest` |
| Multi-symbol rebased compare | `/compare` |
| Pairwise correlation heatmap | `/correlations` |
| Cache admin (per-row + Refresh-ALL buttons) | `/admin/cache` |
| Provider health (success rate, error reasons, latency per provider) | `/admin/health` |

---

## Getting started

### Prerequisites
- Ruby ≥ 3.4 (`.ruby-version` pinned to 3.4.1) and Bundler

### Install + run

```bash
git clone <repo-url>
cd t-money-terminal
make install
make run                   # auto-reload on file changes → http://localhost:4567
```

`make run` and `make dev` are aliases — both launch under `rerun`, which restarts on edits to `app/`, `views/`, `public/`, `scripts/`. Watch / ignore patterns live in [.rerun](.rerun) (cache writes under `data/` are ignored). Use `make serve` for a one-shot run with no auto-reload.

### Credentials

Create `.credentials` at the project root (it's git-ignored). All keys are optional — the app degrades gracefully, hiding panels whose provider is unconfigured.

```
# Core market data
TIINGO_API_KEY=...
ALPHA_VANTAGE_API_KEY=...
FINNHUB_API_KEY=...

# Deeper data
FMP_API_KEY=...           # https://site.financialmodelingprep.com/developer/docs  (250/day; per-symbol whitelist)
POLYGON_API_KEY=...       # https://polygon.io/                                    (5/min)
FRED_API_KEY=...          # https://fred.stlouisfed.org/docs/api/api_key.html      (unlimited)
NEWSAPI_KEY=...           # https://newsapi.org/register                           (100/day; optional fallback to Finnhub)

# Alert delivery (optional — pick any one)
ALERT_WEBHOOK_URL=...     # POST JSON
ALERT_NTFY_TOPIC=...      # ntfy.sh topic
ALERT_EMAIL_TO=...        # plus ALERT_SMTP_HOST / USER / PASS / FROM
```

See [CREDENTIALS.md](CREDENTIALS.md) for signup walkthroughs and the FMP free-tier paywall behaviour.

### Common tasks

```bash
make test                        # RSpec suite (currently 489 examples)
make refresh-cache               # Warm market-data cache for the universe
make refresh-providers           # Warm FMP / FRED / News / Stooq caches
make refresh-all                 # Both, in one shot — REGIONS ∪ portfolio ∪ watchlist
make refresh-symbol SYMBOL=AAPL  # Warm a single symbol end-to-end
make scheduler TIER=quotes       # Tiered cache refresh (quotes/fundamentals/analyst/macro/alerts/all)
make cache-status                # Report cache age / staleness
make check-alerts                # Evaluate active price alerts; dispatch via Notifiers
```

The `/admin/cache` page also has interactive buttons: **Refresh one symbol** (synchronous), **Refresh ALL caches** (background thread with live progress banner), and a per-row ↻ button on every cache entry.

---

## Project layout

```
app/
  main.rb                     # Sinatra routes (TMoneyTerminal class)
  market_data_service.rb      # Provider waterfall + hierarchical cache + market-aware TTL + quote_cached
  recommendation_service.rb   # BUY/HOLD/SELL signal — analyst-aware, with cached_only mode for /portfolio
  providers/                  # FMP, Polygon, FRED, News, Stooq, EDGAR + shared cache_store / throttle / http_client
  analytics/                  # Indicators, risk, Black-Scholes (pure Ruby)
  symbol_index.rb             # Curated + REGIONS + runtime extension store; ticker-pattern guard
  portfolio_store.rb          # Multi-lot positions; FIFO close
  trades_store.rb             # Append-only trade history (with short/long-term subtotals)
  tax_lot.rb                  # Holding-period classifier + earliest-snapshot fallback
  wash_sale.rb                # IRS wash-sale risk flagging on loss-sells
  profile_store.rb            # User investment profile (age, retirement, risk, tax rates) at data/profile.json
  tax_harvester.rb            # Loss-harvest candidate ranking, ST→LT crossings, recommendations
  portfolio_history.rb        # Pivots ImportSnapshotStore snapshots into total + per-symbol time series; sparkline SVG; underwater_streak; movers; allocation_breakdown
  retirement_projection.rb    # Required-CAGR math for /portfolio retirement-progress section (no I/O)
  asset_class_mapper.rb       # Symbol+description → asset class (curated map + description heuristics)
  fidelity_importer.rb        # Broker CSV parser + reconciliation orchestrator
  import_snapshot_store.rb    # Per-source snapshot persistence (audit + drift)
  portfolio_diff.rb           # Snapshot-to-snapshot diff math
  refresh_universe.rb         # Single source of truth: REGIONS ∪ portfolio ∪ watchlist
  refresh_tracker.rb          # In-memory job tracker for background refreshes
  historical_prefetcher.rb    # Async prefetch on import
  health_registry.rb          # Per-provider success/error/latency observations
  watchlist_store.rb / alerts_store.rb / notifiers.rb / correlation_store.rb
views/                        # ERB templates with shared layout
public/                       # style.css, app.js (chart), features.js (search/watchlist/alerts/portfolio)
scripts/                      # refresh_cache, refresh_providers, scheduler, check_alerts, cache_status
spec/                         # RSpec — 489 examples across 18 spec files
data/cache/                   # Hierarchical disk cache
data/imports/                 # Broker import snapshots (audit + drift)
data/porfolio/fidelity/       # Drop your Fidelity Portfolio_Positions_*.csv here
.github/workflows/ci.yml      # GitHub Actions — RSpec + scripts syntax check on every PR
```

---

## Contributing

PR workflow (branch naming, commit style, CI, merge) lives in [CONTRIBUTING.md](CONTRIBUTING.md). Architecture + caching contract + gotchas live in [AGENTS.md](AGENTS.md).

## License

MIT

> All recommendations, analytics, and valuations are for informational purposes only. Not financial advice.
