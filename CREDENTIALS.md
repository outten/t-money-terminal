# API Credentials Setup

Provide API keys in a `.credentials` file at the project root. **All keys are
optional** — the app degrades gracefully, hiding panels whose provider is
unconfigured. The provider waterfall means a single working key is enough
for quotes/historicals; deeper data (fundamentals, options, macro, news)
requires its own key.

`.credentials` is git-ignored. `dotenv` loads it automatically; you don't
need to source it manually.

---

## 1. Obtain API keys (all free tier)

### Core market data

- **Tiingo** — historical price data + quotes
  - Sign up at https://www.tiingo.com → Account → API → copy your token
  - Free tier: ample for personal use; rate-limited per minute
- **Alpha Vantage** — quotes + weekly historical fallback
  - Sign up at https://www.alphavantage.co/support/#api-key
  - Free tier: **5 req/min, 25 req/day** — used as last-resort fallback only
- **Finnhub** — analyst recommendations, company profiles, news, candles (paywalled now)
  - Sign up at https://finnhub.io
  - Free tier: 60 req/min

### Deeper data

- **Financial Modeling Prep (FMP)** — key metrics, ratios, DCF, earnings calendar
  - Sign up at https://site.financialmodelingprep.com/developer/docs
  - Free tier: 250 req/day
  - **⚠️ Free tier whitelists symbols.** AAPL/MSFT/GOOGL etc. return 200; ADRs (FANUY, LVMUY, TM, SAP, ASML, BP), most ETFs (VOO, IVV, SCHD, AVGO), and mutual funds (FFTHX, FXAIX, TRRJX) return **HTTP 402**. The app handles this automatically: on 402 we write a 24 h tombstone at `data/cache/fmp/_paywalled_/<SYM>.txt` and short-circuit future requests for that symbol. You'll see paywalled tickers as a one-time `:error` in `/admin/health` and then they disappear from the metric. Re-tested daily.
- **Polygon.io** — options chains + daily aggregates (your primary historical source if Yahoo throttles your IP)
  - Sign up at https://polygon.io/
  - Free tier: 5 req/min, 2 years of history
- **FRED (St. Louis Fed)** — Fed funds, treasuries, CPI, unemployment, VIX
  - Sign up at https://fred.stlouisfed.org/docs/api/api_key.html
  - Free tier: effectively unlimited
- **NewsAPI** — fallback news source (Finnhub is primary)
  - Sign up at https://newsapi.org/register
  - Free tier: 100 req/day

### Alert delivery (pick any combination)

The price-alert system (`make check-alerts` / scheduled cron) dispatches
via [Notifiers](app/notifiers.rb). All channels are optional; only those
with env vars set are tried, and failures in one don't block the others.

- **Webhook** — `ALERT_WEBHOOK_URL=https://...` POSTs JSON. Slack-incoming-hooks shape works.
- **ntfy.sh** — `ALERT_NTFY_TOPIC=your-topic` (optional `ALERT_NTFY_SERVER=https://ntfy.sh`)
- **SMTP email** — `ALERT_EMAIL_TO=you@example.com` plus:
  - `ALERT_SMTP_HOST` (e.g. `smtp.gmail.com`)
  - `ALERT_SMTP_USER` / `ALERT_SMTP_PASS`
  - `ALERT_SMTP_FROM` (defaults to `_USER`)
  - `ALERT_SMTP_PORT` (default 587, STARTTLS)

---

## 2. Create `.credentials`

At the project root, create a file named `.credentials`:

```
# Core market data (recommended: at minimum Tiingo + Finnhub)
TIINGO_API_KEY=your_tiingo_token_here
ALPHA_VANTAGE_API_KEY=your_alpha_vantage_key_here
FINNHUB_API_KEY=your_finnhub_key_here

# Deeper data (highly recommended — Polygon especially if Yahoo's throttling you)
FMP_API_KEY=your_fmp_key_here
POLYGON_API_KEY=your_polygon_key_here
FRED_API_KEY=your_fred_key_here
NEWSAPI_KEY=your_newsapi_key_here

# Alert delivery (optional — pick one)
ALERT_NTFY_TOPIC=tmoney-alerts
# ALERT_WEBHOOK_URL=https://hooks.slack.com/services/...
# ALERT_EMAIL_TO=you@example.com
# ALERT_SMTP_HOST=smtp.gmail.com
# ALERT_SMTP_USER=you@gmail.com
# ALERT_SMTP_PASS=your-app-password
# ALERT_SMTP_FROM=you@gmail.com
```

`.env` is also auto-loaded as a fallback, but `.credentials` is the canonical source.

---

## 3. What works without keys

- Yahoo (no auth) — quotes + historicals
- Stooq (no auth) — international index data
- SEC EDGAR (no auth, descriptive UA header) — wired but no view consumes it yet

So even with **zero keys** the dashboard, region pages, and chart will populate via Yahoo/Stooq. You'll lose: analyst consensus, fundamentals, news, macro panel, alert delivery.

---

## 4. Security

- **Never commit `.credentials`.** It's in `.gitignore`. Same for `data/portfolio.json`, `data/trades.json`, `data/symbols_extended.json`, `data/imports/`, `data/porfolio/fidelity/*` — all private state.
- The `.env.example` / `.credentials.example` pattern is fine; just don't put real keys in either.

---

## 5. After setup

```bash
make refresh-all   # warm every cache the app uses across your full universe
make run           # start at http://localhost:4567
```

If you want a single symbol's caches built lazily, just visit `/analysis/SYM` — the waterfall handles first fetch and caches everything for the next render.
