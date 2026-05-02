# T Money Terminal — Instructions

User-facing setup + walkthrough. For architecture see [AGENTS.md](AGENTS.md);
for credential signup see [CREDENTIALS.md](CREDENTIALS.md).

---

## 1. Prerequisites

- Ruby ≥ 3.4 (`.ruby-version` is pinned to 3.4.1)
- Bundler (`gem install bundler`)

## 2. Install

```bash
git clone <repo-url>
cd t-money-terminal
make install
```

## 3. API keys (optional but strongly recommended)

The app degrades gracefully — a totally key-less install still runs via Yahoo + Stooq for quotes, charts, and international indices. To unlock fundamentals, analyst consensus, news, macro, and a Polygon historical fallback for symbols Yahoo throttles, fill in `.credentials`:

```
TIINGO_API_KEY=...
ALPHA_VANTAGE_API_KEY=...
FINNHUB_API_KEY=...
FMP_API_KEY=...        # 250/day; per-symbol whitelist
POLYGON_API_KEY=...    # 5/min
FRED_API_KEY=...       # unlimited (macro)
NEWSAPI_KEY=...        # 100/day; optional Finnhub fallback
```

See [CREDENTIALS.md](CREDENTIALS.md) for the full walkthrough including the FMP free-tier paywall behaviour.

## 4. Run

```bash
make run                # auto-reloads on file changes → http://localhost:4567
```

`make run` and `make dev` are aliases. Use `make serve` for a one-shot run with no auto-reload.

---

## 5. Pages

| Page | URL | What it shows |
|---|---|---|
| Dashboard | `/dashboard` | All tracked regions + macro snapshot + intl. indices + watchlist + upcoming earnings + provider-degradation banner when applicable |
| Region | `/region/us`, `/region/japan`, `/region/europe` | Per-region symbols + region-level chart |
| Per-symbol analysis | `/analysis/:symbol` | Quote, fundamentals (FMP), DCF, news, candles, RSI/MACD/SMA overlays, Black-Scholes, your position widget, alerts |
| Portfolio | `/portfolio` | Multi-lot positions with live unrealized P&L, signal badges, drift link, broker import button |
| Trade history | `/trades` | Append-only BUY/SELL log with realized P&L YTD + lifetime |
| Portfolio drift | `/portfolio/drift` | What changed between your two most recent broker imports |
| Tax-loss harvesting | `/portfolio/tax-harvest` | Underwater lots ranked by estimated tax savings · ST→LT crossing watchlist · YTD $3 k cap progress · replacement-security suggestions |
| Compare | `/compare?symbols=AAPL,MSFT&period=1y` | Rebased-to-100 multi-symbol performance chart (≤ 6 symbols) |
| Correlations | `/correlations?symbols=...&period=1y` | Pairwise daily-return correlation heatmap |
| Cache admin | `/admin/cache` | Cache state + per-row refresh buttons + Refresh-ALL button |
| Provider health | `/admin/health` | Per-provider success rate, error reasons, latency |

---

## 6. Importing a Fidelity portfolio

The app's daily workflow is built around a Fidelity CSV export.

1. Log into Fidelity → **Accounts & Trade** → **Portfolio Positions** → **Download** → choose CSV.
2. Save the file (Fidelity names it `Portfolio_Positions_<Mmm>-<DD>-<YYYY>.csv`) into `data/porfolio/fidelity/` (yes, with the typo Fidelity ships in their dir name — it's kept for compatibility).
3. Open `/portfolio` and click **Import latest Fidelity export**.

What happens:
- Lots in your portfolio are replaced with the broker's per-symbol average cost basis.
- Manual lots for symbols *not* in the file are preserved.
- Unknown tickers (FANUY, KLAC, etc.) are auto-registered so `/analysis/:symbol` resolves.
- Your quote cache is primed from the file's Last Price column → `/portfolio` renders instantly.
- A background thread fetches 1-year historicals for every imported symbol, so the first `/analysis/:symbol` click is also instant.
- The full parsed payload is persisted as a snapshot for audit + drift comparison.

After your second import you can visit `/portfolio/drift` to see what changed: positions added, sold, scaled up/down — sorted biggest-mover-first.

### Backfilling history from older CSVs

If you've collected a stack of `Portfolio_Positions_*.csv` files from prior days (e.g. dropping a week's worth at once after market close), `/portfolio` shows a **"Backfill N CSVs into snapshots"** button whenever there's at least one CSV without a matching JSON snapshot. Clicking it parses each pending CSV and writes the JSON snapshot — but does NOT touch your current portfolio, the quote cache, or trigger historical prefetch. Each historical CSV represents a past day's holdings, not the current state, so the importer's regular reconciliation logic stays out of the way.

Once 2+ snapshots exist, the **value-over-time chart** at the top of `/portfolio` lights up (one data point per import, with day-over-day delta in the tooltip), and the positions table grows a **Trend column** with a small green/red sparkline per symbol showing its market-value trajectory across the snapshot history.

The backfill button scans both `data/porfolio/fidelity/` (the canonical CSV input dir) and `data/imports/fidelity/` (the snapshot output dir), so dropping CSVs in either place still works.

---

## 6a. Tax-loss harvesting

`/portfolio/tax-harvest` (linked from the `/portfolio` subtitle) inspects every open lot and ranks the underwater ones by estimated tax savings.

**Set up your profile first** — the analysis needs your age, retirement age, risk tolerance, and federal marginal rates (and optionally state + NIIT). The page renders an empty state until `current_age` is set; click the "Set up your profile" form to fill it in. Profile lives at `data/profile.json`.

**Risk tolerance drives which losses are worth the friction:**
- `aggressive` — harvest losses ≥ 0.5 % of cost basis
- `moderate` — harvest losses ≥ 2 %
- `conservative` — harvest losses ≥ 5 %

**Per-candidate recommendation** is one of:
- `harvest` — loss is meaningful, no wash-sale risk, holding period favours acting now
- `wait` — short-term loss days from flipping to long-term and the conservative profile is set
- `skip` — loss too small for the risk tolerance, OR a same-symbol BUY landed within ±30 days (wash-sale risk)

**Other sections:**
- **YTD realised** — short / long / net, plus how much of the $3 000 ordinary-offset cap is already used and the carryforward estimate.
- **Crossing ST → LT in ≤ 30 days** — flagged so you don't realise a near-LT loss without thinking; for unrealised gains in the same window, waiting saves tax.
- **Underwater streak (per candidate)** — how many consecutive snapshots the position has been red, plus calendar days since the streak began. Conviction signal: a position red for 3 days is noise; red for 60+ days is conviction. Drives a low / med / high badge alongside each candidate.
- **Replacement suggestions** — different-INDEX ETFs (SPY → VTI, QQQ → VUG, etc.). Same-INDEX trios (SPY ↔ VOO ↔ IVV) are intentionally NOT recommended.

### Retirement progress on /portfolio

Once you've also set a **retirement target value** in the profile form, `/portfolio` shows a **Retirement progress** section with four cards: years remaining, current portfolio value, target at retirement (with the gap below), and the **required compound annual return** to hit the target. The section is hidden until current age + retirement age + target are all set.

Below the cards, a **caveated verdict** reads "On track" / "Tight" / "Not on track" by comparing your required CAGR against long-run historical norms cited from two sources (NYU Stern's Damodaran 1928–2023 dataset and the Bogleheads historical-returns wiki — both linked, opens in a new tab). Thresholds: ≤ 5% sits below the 10-yr Treasury average; 5–8% matches a 60/40 balanced mix; 8–10% needs equity-heavy positioning; &gt; 10% exceeds the S&P 500's long-run average. The verdict is directional, not a forecast — sequence of returns, fees, taxes, contributions, asset mix, and inflation are all unmodelled.

This is **decision support, not tax advice**. The page does not file your return, account for AMT, prior-year carryforwards, or QDI interactions.

---

## 7. Refreshing the cache

The contract: page renders never fire providers. To pull fresh data you trigger a refresh explicitly.

| Action | What it does |
|---|---|
| **`/admin/cache` → Refresh ALL** | Background thread iterates your full universe (REGIONS + portfolio + watchlist) and rebuilds every cache entry. Live progress banner. |
| **`/admin/cache` → per-row ↻** | Bust + refetch quote / analyst / profile / 1-year historical for one symbol. Synchronous (~5-10 s). |
| **`/admin/cache` → Refresh one symbol form** | Same as ↻ but type the symbol directly. |
| **`make refresh-all`** | Same as Refresh ALL but from the CLI. |
| **`make refresh-symbol SYMBOL=AAPL`** | Same as ↻. |
| **`make scheduler TIER=quotes`** | Tiered refresh; tiers are `quotes`, `fundamentals`, `analyst`, `macro`, `alerts`, `all`. Suitable for cron / launchd. |
| **A Fidelity import** | Implicitly: primes quote cache + busts historicals + spawns prefetch thread. |

Fidelity import is the most efficient way to refresh — it covers exactly the symbols you actually hold, with broker-authoritative prices.

---

## 8. Price alerts

1. On `/analysis/:symbol`, enter a threshold (e.g. "alert when AAPL is above $250").
2. Run `make check-alerts` (or schedule it via cron — `*/15 9-16 * * 1-5` is the suggested rhythm during market hours).
3. Triggered alerts append to `data/alerts_triggered.log`.
4. **Optional delivery**: configure `ALERT_NTFY_TOPIC`, `ALERT_WEBHOOK_URL`, or `ALERT_EMAIL_TO` + `ALERT_SMTP_*` and the alert checker will dispatch via [Notifiers](app/notifiers.rb).

---

## 9. Interpreting recommendations

The Signal column on `/portfolio` and the Recommendation badge on `/analysis/:symbol` use the simplest sensible heuristic:

- **Analyst Consensus** — when Finnhub's analyst recommendations are cached for the symbol, score = (strongBuy×2 + buy×1 + hold×0 + sell×−1 + strongSell×−2) / total. Score > 0.5 = BUY, < −0.5 = SELL, else HOLD.
- **Momentum Signal** (fallback when no analyst data) — based on day-change percentage. > +1 % = BUY, < −1 % = SELL, else HOLD.

The Notes column on `/portfolio` adds context computed from cached historicals: concentration warnings (> 20 % of portfolio), RSI extremes (> 70 / < 30), trend vs SMA-200, and any broker accounts the symbol is held in.

> ⚠️ Recommendations are heuristic and **not financial advice**. Always do your own research before making investment decisions.

---

## 10. Light/Dark mode

Click the theme toggle in the header. Your preference is saved across sessions via `localStorage`.

---

## 11. Data sources

The app uses a **provider waterfall**: each fetch tries multiple providers in order, falling back on failure or rate-limit. With keys configured, your IP is throttle-resilient against any single source.

See [README.md](README.md) for the full provider table and waterfall ordering, and [CREDENTIALS.md](CREDENTIALS.md) for signup links and free-tier limits.

Every external data source is publicly accessible (no scraping, no ToS-violating endpoints). All recommendations and analytics are computed locally from cached data.
