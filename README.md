# T Money Terminal

A self-hosted, open-source investment terminal inspired by the Bloomberg Terminal — built with Ruby and Sinatra, powered entirely by **free-tier APIs**. All data is cached on disk with a 1-hour TTL and a persistent fallback layer so pages keep rendering when upstreams throttle.

---

## What it does

**Market data (waterfall, free tier)**
Quotes and historical OHLCV are fetched through a provider waterfall so any single outage or rate-limit is survivable:

- Quotes: Tiingo → Alpha Vantage → Finnhub → Yahoo
- Historical: Yahoo → Finnhub candles → Tiingo → Alpha Vantage (weekly)
- Analyst consensus & company profiles: Finnhub
- Hardcoded profiles for the four tracked ETFs (SPY, QQQ, EWJ, VGK)

**Deeper data providers** ([app/providers/](app/providers/))

| Provider | Used for | Free tier |
|---|---|---|
| Financial Modeling Prep (FMP) | Key ratios, DCF, earnings calendar, key metrics | 250/day |
| Polygon.io | Options chains, IV, open interest | 5/min |
| FRED | Fed funds, 3M/10Y treasury, CPI, unemployment, VIX | unlimited |
| Finnhub News + NewsAPI | Per-symbol headlines | 60/min / 100/day |
| Stooq | Nikkei, Hang Seng, DAX, FTSE, CAC, S&P 500, Nasdaq, Dow | none required |
| SEC EDGAR | Latest 10-K / 10-Q / 8-K filings | none required (UA header) |

**Pure-Ruby analytics** ([app/analytics/](app/analytics/), zero API cost — runs off cached bars)

- [indicators.rb](app/analytics/indicators.rb) — SMA, EMA, MACD, RSI (Wilder), Bollinger Bands
- [risk.rb](app/analytics/risk.rb) — annualized return & vol, Sharpe, Sortino, max drawdown, historical & parametric VaR, beta, correlation, date alignment
- [black_scholes.rb](app/analytics/black_scholes.rb) — European price, full Greeks (Δ/Γ/Vega/Θ/ρ), implied vol (bisection), historical vol

**Charting**
TradingView [lightweight-charts](https://www.tradingview.com/lightweight-charts/) (CDN, MIT) with four synchronized panes — price (candles + SMA 20/50/200 + Bollinger), volume histogram coloured by candle direction, RSI(14) with 30/70 reference lines, and MACD(12/26/9) line + signal + histogram. Crosshair OHLCV readout, period toggle (1d / 1m / 3m / YTD / 1y / 5y), log-scale toggle, dark-mode palette swap.

**Productivity**

- **Universal search** — type-ahead over ~55 curated symbols (every region ticker plus large-cap US names and sector ETFs), keyboard navigable (↑ ↓ Enter Esc).
- **Watchlist** — server-persisted to `data/watchlist.json` (atomic write + mutex), rendered with live quotes on the dashboard and a ☆/★ toggle on `/analysis/:symbol`.
- **Price alerts** — threshold alerts persisted to `data/alerts.json`. `make check-alerts` evaluates every active alert (cron-friendly: `*/15 9-16 * * 1-5`) and appends triggered ones to `data/alerts_triggered.log`.
- **Compare mode** — `/compare?symbols=AAPL,MSFT,GOOGL&period=1y` renders a rebased-to-100 multi-symbol performance chart (up to 6 symbols).
- **CSV export** — `/api/export/:symbol/:period.csv` returns OHLCV plus the full indicator series.

---

## Pages

| Page | URL |
|---|---|
| Dashboard (summary + macro + intl. indices + watchlist + upcoming earnings) | `/dashboard` |
| Region (US / Japan / Europe) | `/region/us`, `/region/japan`, `/region/europe` |
| Per-symbol analysis (fundamentals, DCF, news, candles, analytics, alerts) | `/analysis/:symbol` |
| Multi-symbol rebased compare | `/compare` |
| Cache admin | `/admin/cache` |

---

## Getting started

### Prerequisites
- Ruby ≥ 3.0 and Bundler

### Install & run

```bash
git clone <repo-url>
cd t-money-terminal
make install
make run              # auto-reload on file changes → http://localhost:4567
```

`make run` and `make dev` are aliases — both launch under `rerun`, which
restarts the server whenever a Ruby/ERB/JS/CSS file changes under `app/`,
`views/`, `public/`, or `scripts/`. Watch/ignore patterns live in
[.rerun](.rerun) (cache writes under `data/` are ignored so the server doesn't
thrash). Use `make serve` for a one-shot run with no auto-reload.

### Credentials

Create `.credentials` at the project root (it's git-ignored). All keys are optional — the app degrades gracefully, hiding panels whose provider is unconfigured.

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

See [CREDENTIALS.md](CREDENTIALS.md) for signup walkthroughs.

### Common tasks

```bash
make test                        # RSpec suite (138 examples)
make refresh-cache               # Warm market-data cache (respects rate limits)
make refresh-providers           # Warm FMP / FRED / News / Stooq caches
make refresh-all                 # Both of the above in one shot
make refresh-symbol SYMBOL=AAPL  # Warm a single symbol end-to-end
make cache-status                # Report cache age / staleness
make check-alerts                # Evaluate active price alerts (cron-friendly)
```

The UI also has **Refresh** buttons on every page that bust the relevant slice of the cache without leaving the browser.

---

## Project layout

```
app/
  main.rb                     # Sinatra routes
  market_data_service.rb      # Provider waterfall + hierarchical cache
  recommendation_service.rb   # Buy/Sell/Hold signal logic
  providers/                  # FMP, Polygon, FRED, News, Stooq, EDGAR + shared cache/throttle
  analytics/                  # Indicators, risk, Black-Scholes (pure Ruby)
  symbol_index.rb             # Search universe
  watchlist_store.rb          # File-backed watchlist
  alerts_store.rb             # File-backed alerts
views/                        # ERB templates (shared layout)
public/                       # style.css, app.js (chart), features.js (search/watchlist/alerts)
scripts/                      # refresh_cache, refresh_providers, cache_status, check_alerts
spec/                         # RSpec (app, services, providers, analytics, section4)
data/cache/                   # Hierarchical 1-hour TTL disk cache
```

---

## License

MIT

> All recommendations, analytics, and valuations are for informational purposes only. Not financial advice.
