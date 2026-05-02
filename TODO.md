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

### [PR #18] — Fix watchlist 0.0% bug (Tiingo single-bar daily endpoint)

- **Bug**: every quote on `/dashboard`'s My Watchlist showed `0.0%` change. Root cause: `MarketDataService.fetch_from_tiingo_quote` requested `https://api.tiingo.com/tiingo/daily/<symbol>/prices` without `startDate`, which returns ONLY the latest EOD bar — so `data.length > 1` was false, `prev_close` collapsed to `close`, and `change_pct` always computed as 0. Tiingo is first in the provider waterfall, so every cache-hit symbol was affected.
- **Fix**: pass `startDate=<7 days ago>` so Tiingo returns ~5 trading sessions of bars (covers any 3-day weekend / market holiday). Extracted the prev-close math into `change_pct_from_tiingo_bars` so the regression is testable without HTTP.
- 6 new tests in [spec/services_spec.rb](spec/services_spec.rb): empty/nil bars, single-bar regression case, two-bar happy path, adjClose fallback, divide-by-zero guard, and an integration test asserting `startDate=` appears in the URL.
- Live verified: bust-cache via `/admin/refresh/symbol`, then `/dashboard` shows CMCSA at +0.55%, CAT at -0.05% — real values instead of 0.0%.

**Tests:** 553 examples, 0 failures across 20 spec files.

### [PR #17] — Retirement planning sub-page at /portfolio/retirement

- New view [views/retirement.erb](views/retirement.erb) and route `GET /portfolio/retirement` rendering the full retirement projection (progress + spending sustainability + verdict + caveats + citations) on its own page.
- `/portfolio` retirement section replaced with a **compact preview tile** showing the three headline numbers (years remaining, required CAGR, years portfolio lasts) plus shortened verdict snippets and a "See full projection & verdict →" button. Tile renders even before the profile is configured, with a link to the setup form.
- New view handles the unconfigured-profile case gracefully (clear "→ Set up your profile" call-to-action) and degrades to "set monthly spending" prompt when target is set but spending isn't.
- Pages-table updated in README.md and Instructions.md; new "Retirement planning sub-page" section added to Instructions.md.
- 4 new route tests in [spec/retirement_projection_spec.rb](spec/retirement_projection_spec.rb) (empty-profile state, configured projection, spending sub-section render, /portfolio link).

**Tests:** 547 examples, 0 failures across 20 spec files. (Superseded by PR #18 — see above.)

### [PR #16] — Retirement spending sustainability ("is it sustainable, and for how long?")

- **`ProfileStore`**: two new fields — `monthly_retirement_spending` (today's dollars, optional) and `post_retirement_real_return` (default 0.04). Both range-validated, partial-update semantics preserved.
- **`RetirementProjection.spending_analysis`** — pure-math helper that takes `monthly_retirement_spending` + `post_retirement_real_return` + the (real) `target_value` and returns: monthly + annual target spending, sustainable (perpetual) monthly rate, implied withdrawal rate, **years until portfolio depletion** (`n = -ln(1 - r·B/W) / ln(1+r)`, with proper handling of `r=0`, `r<0`, and the perpetual case `W ≤ r·B`), plus a verdict bucket and human summary.
- **Verdict bands**: `perpetual` (W ≤ r·B) / `comfortable` (≥40y) / `thirty_year_safe` (≥30y, the canonical 4% rule horizon) / `tight` (≥25y) / `underfunded` (≥15y) / `severely_underfunded`.
- **Retirement spending section** on `/portfolio` — four cards (monthly spend / sustainable monthly / withdrawal rate / years portfolio lasts), color-coded, with the human verdict in a left-bordered call-out matching the existing retirement-progress block.
- **New citation**: Bogleheads SWR wiki (Trinity-study summary, 4% rule). Existing Damodaran / Bogleheads-returns / FRED-PCEPI cites preserved.
- **Profile form** on `/portfolio/tax-harvest` gains the two new inputs.
- 18 new tests in [spec/retirement_projection_spec.rb](spec/retirement_projection_spec.rb) (years_until_depletion edge cases — zero / negative return, perpetual boundary, finite case; spending_analysis bucket coverage across perpetual / comfortable / thirty_year_safe / severely_underfunded) and [spec/tax_harvest_spec.rb](spec/tax_harvest_spec.rb) (ProfileStore field persistence, range validation, defaults).
- Verified live against my own numbers: $10K/mo at 4% real return → 46 years coverage (`comfortable`); sweep across $8K → $20K shows the verdict moving cleanly through every band (`perpetual` at $8K → `severely_underfunded` at $20K).

**Tests:** 543 examples, 0 failures across 20 spec files. (Superseded by PR #17 — see above.)

### [PR #15] — Account-type allocation + expense-ratio audit + inflation-aware retirement target

- **Q. Account-type allocation on /portfolio** — new section groups holdings by broker account name and normalizes each into a tax kind via [`AccountClassifier`](app/account_classifier.rb) (`taxable / roth / traditional_ira / tax_deferred_401k / deferred_annuity / hsa / other`). Multi-account holdings are split evenly across accounts with the imprecision honestly disclosed in the UI footer. Foundation for the planned U / V / W (Roth conversion, RMD projection, tax-efficient location). Verified live: $1.41M Taxable / $386K 401(k) / $257K Deferred Annuity / $38K Roth.
- **S. Expense-ratio audit on /portfolio** — new section joins each position to a curated [`ExpenseRatioMap`](app/expense_ratio_map.rb) (~70 popular ETFs + the user's specific top-by-value holdings + their 401(k)'s institutional-class CUSIPs). Computes annual fee in dollars per holding (`market_value × ER`); shows total annual fee drag, weighted-average ER, coverage %, and an expandable top-25 fee-drag table. Individual common stocks/ADRs are auto-treated as 0% ER (no fund management fee) so coverage isn't misleadingly low. Live: 99.2% coverage; ~$5.4K/year drag at 0.26% weighted avg.
- **T. Inflation-adjusted retirement target** — `retirement_target_value` is now interpreted as TODAY's dollars (real); new `inflation_assumption_rate` field on [`ProfileStore`](app/profile_store.rb) (default 2.5%) drives a parallel **nominal** target = real × `(1+inflation)^years`. [`RetirementProjection.project`](app/retirement_projection.rb) emits both `real_required_return` and `nominal_required_return`; the verdict uses nominal because that's the rate the portfolio must clear. Verified live: a 2.63% nominal-only verdict became a 5.21% nominal / 2.64% real verdict — a different bucket (`on_track_safe` → `on_track_balanced`), exactly the "different verdict" we predicted in the analysis. New citation added: FRED PCEPI for the inflation reference.
- **`AssetClassMapper.individual_stock?`** — discrete predicate exposing the existing description-suffix discriminator so the expense audit can correctly count individual common stocks as fund-fee-free instead of unmapped. Pattern extended to catch more entity-type suffixes (`CO`, `PLC`, `LLC`, `LTD`, `INCORPORATED`, `NY REGISTRY`, `ISIN`).
- 36 new tests across 4 spec files: [spec/account_classifier_spec.rb](spec/account_classifier_spec.rb) (12 — kind detection across Roth / 401k / IRA / annuity / HSA / taxable), [spec/expense_ratio_map_spec.rb](spec/expense_ratio_map_spec.rb) (7 — popular ETFs, user's actual holdings, CUSIPs, case-insensitivity), extensions to [spec/portfolio_history_spec.rb](spec/portfolio_history_spec.rb) (10 — account_breakdown summing/sorting, multi-account split, expense_ratio_audit individual-stock handling, weighted_avg math), [spec/retirement_projection_spec.rb](spec/retirement_projection_spec.rb) (4 — inflation-aware real/nominal split, alias preservation, zero-inflation degeneracy, at_goal at nominal). [spec/tax_harvest_spec.rb](spec/tax_harvest_spec.rb) (3 — inflation_assumption_rate persistence/validation/default).

**Tests:** 525 examples, 0 failures across 20 spec files. (Superseded by PR #16 — see above.)

### [PR #14] — Performance leaders/laggards + asset-class breakdown
- **`PortfolioHistory.movers`** — top 5 gainers + top 5 laggards across the snapshot window, ranked by **per-share price change** (not market_value change — that would conflate price action with the user's own buy/sells). Skips positions where shares drifted >5% between first and last snapshot (catches stock splits like BKNG 25:1 / VOOG 6:1, large buys, broker data quirks). `min_value:` knob (default $1000) filters tiny positions whose % rankings are noise. Each row carries the full per-symbol series for inline-SVG sparklines.
- **Performance leaders & laggards section** on `/portfolio` — two-column layout (gainers / laggards), with sparkline per row; hidden when there are fewer than 2 snapshots.
- **`AssetClassMapper`** ([app/asset_class_mapper.rb](app/asset_class_mapper.rb)) — classifies a holding into one of nine classes (target-date / us_stocks / intl_stocks / bonds / real_estate / commodities / balanced / cash / unmapped) using a hand-curated symbol map plus description regex rules. Symbol map covers ~50 popular ETFs/MFs + the user's biggest unmapped holdings (FMAGX, FBGRX, FVDFX, FSMD; mega-cap individual stocks NVDA/AAPL/MSFT/GOOGL/AMZN/META/AVGO/JPM/AMAT/MU/GE/GEV/KLAC/XOM; ADRs TSM/SHEL). Description rules catch ADR markers (`SPON ADS`, `ADS EA REP`), abbreviations (`INTL`, `INTNL`, `EMNG MKT`), Fidelity active-fund names (Magellan, Blue Chip, Value Discovery, Multifactor), and individual-stock suffixes (`COMMON STOCK`, `INC COM`, `CORP COM`, `CAP STK`, trailing `COM`). `unmapped` is reported honestly so the bucket size signals where the map needs more coverage.
- **`PortfolioHistory.allocation_breakdown`** — pulls the latest snapshot, classifies via AssetClassMapper, returns `{rows: [{class, label, value, pct, count, symbols}, ...], total_value, as_of}`.
- **Asset-class breakdown section** on `/portfolio` — table with class label, $ value, % of portfolio (with inline horizontal bar), position count, and top 3 holdings per class. Linked symbols deep-link to `/analysis/:symbol`.
- 36 new tests in [spec/asset_class_mapper_spec.rb](spec/asset_class_mapper_spec.rb) (classification edge cases) + new examples in [spec/portfolio_history_spec.rb](spec/portfolio_history_spec.rb) covering movers (split-aware, drift filter, dividend tolerance) and allocation_breakdown.
- Verified live: classifies ~96% of a real 528-position $2M portfolio out of the box; gainers/laggards return realistic 1-month moves (MRVL +73%, PRYMY +41%, PWR +35%) instead of the share-count-conflated noise that the v0 market-value approach produced.

**Tests:** 489 examples, 0 failures across 18 spec files. (Superseded by PR #15 — see above.)

### [PR #13] — Underwater-streak on tax-harvest candidates + retirement progress on /portfolio
- **`PortfolioHistory.underwater_streak(symbol)`** ([app/portfolio_history.rb](app/portfolio_history.rb)) — counts consecutive snapshots ending at the latest where `market_value < cost_value`, returning `{snapshots:, since:, days:, currently_underwater: true}` or nil. Per-symbol series now also carries `cost_value` so the check is canonical.
- **Underwater column** on `/portfolio/tax-harvest` candidates table — surfaces the streak with a conviction-level badge (low/med/high based on snapshot count) plus "N days since YYYY-MM-DD." Distinguishes noise (red 3 days) from conviction (red 60+ days) at a glance, sharpening the harvest-vs-wait call.
- **`TaxHarvester.analyse` / `.candidates`** now accept an optional `per_symbol_history:` argument; when provided, each candidate row gains a `:underwater` field. Wiring is preserved end-to-end through `GET /portfolio/tax-harvest` and `GET /api/portfolio/tax-harvest`.
- **`RetirementProjection`** ([app/retirement_projection.rb](app/retirement_projection.rb)) — pure-math helper computing `required_annual_return` (CAGR from current → target over N years) plus a `project(profile:, current_value:)` bundle for the view (years remaining, current, target, gap, required CAGR, status: at_goal / short).
- **Retirement progress section** on `/portfolio` — four cards (years remaining, current value, target, required annual return) hidden until `current_age` + `retirement_age` + `retirement_target_value` are all set in `ProfileStore`. Falls back to the latest snapshot value when `PortfolioStore` is empty so snapshot-only users still see it.
- **Caveated verdict** under the cards — maps the required CAGR to one of `on_track_safe` / `on_track_balanced` / `tight_equity` / `not_on_track`, anchored to long-run nominal CAGRs from cited sources (NYU Stern Damodaran 1928–2023 dataset; Bogleheads historical returns wiki). Sources are linked with `target="_blank" rel="noopener noreferrer"` so they open in a new tab. Caveat block calls out that the verdict is directional, not a forecast (sequence of returns, fees, taxes, contributions, asset mix, inflation all unmodelled).
- **`ProfileStore.retirement_target_value`** added (validated as non-negative float, partial-update semantics preserved). Profile config form on `/portfolio/tax-harvest` gains the input.
- 6 new tests in [spec/retirement_projection_spec.rb](spec/retirement_projection_spec.rb) + 9 new in [spec/portfolio_history_spec.rb](spec/portfolio_history_spec.rb) (underwater streak edge cases) + 5 new in [spec/tax_harvest_spec.rb](spec/tax_harvest_spec.rb) (per_symbol_history wiring + retirement_target_value persistence).

**Tests:** 453 examples, 0 failures across 17 spec files. (Superseded by PR #14 — see above.)

### [PR #12] — Portfolio value-over-time chart + per-position sparklines + Fidelity backfill
- **PortfolioHistory** ([app/portfolio_history.rb](app/portfolio_history.rb)) — pivots `ImportSnapshotStore` snapshots into a total time series (date / total_value / total_cost / unrealized_pl / day-over-day delta) and a per-symbol time series for sparklines. Inline-SVG sparkline renderer (no JS dependency, green/red by direction).
- **Value-over-time chart** at the top of `/portfolio` — Chart.js line chart of total portfolio value across every Fidelity snapshot, with hover tooltip showing date + total + Δ vs prior + unrealized P&L. Three summary cards (latest value, day-over-day change, unrealized P&L). Hidden until 2+ snapshots exist; single-snapshot empty state when only one.
- **Trend column** on the positions table — inline-SVG sparkline per symbol with hover-tooltip carrying snapshot count + date range + total $/% change.
- **`FidelityImporter.backfill_snapshots!`** — snapshots every Fidelity CSV that doesn't yet have a JSON snapshot, scanning BOTH `data/porfolio/fidelity/` (canonical input) AND `data/imports/fidelity/` (output dir, in case CSVs got dropped there by mistake). Does NOT touch PortfolioStore, the quote cache, or trigger historical prefetch — purely additive snapshot creation. Idempotent.
- **Backfill button** on `/portfolio` (with pending-CSV count) + POST `/portfolio/import/fidelity/backfill` route + `GET /api/portfolio/history` JSON peer.
- 24 new tests in [spec/portfolio_history_spec.rb](spec/portfolio_history_spec.rb).

**Tests:** 427 examples, 0 failures across 16 spec files. (Superseded by PR #13 — see above.)

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

> Direction: this is a single-user retirement-planning tool for a 56-year-old retiring at 63 (~7-year horizon, ~$2M across taxable / 401(k) / Roth / deferred annuity). New work should serve **retirement decisions**, not aesthetic / academic features. Several previously-listed items have been dropped below for that reason.

### Tier 1 — direct retirement-decision value [P0–P1]

> Q (account-type aggregation), S (expense-ratio audit), and T (inflation-adjusted retirement target) shipped in PR #15. See above.

#### R. Annual income / dividend forecast [P1]
- **Problem**: for someone 7 years from retirement, "how much will my portfolio generate in income each year?" is the central question for the "can I live off the dividends?" sanity check. We don't surface this anywhere.
- **Plan**: pull dividend yield per holding from FMP (`/quote` already returns it for ETFs/stocks; mutual-fund yield via `/profile`) → multiply by share count → aggregate per account-type and total. Add a card to `/portfolio` showing "Projected annual income" + per-class income breakdown.
- **Cost**: 1 day. Caches like the rest of the FMP data.

### Tier 2 — important but builds on Tier 1 [P1–P2]

#### U. Roth conversion window analyzer [P1, depends on Q]
- **Problem**: between retirement at 63 and RMDs at 73 there's a 10-year window of low-bracket years to convert traditional 401(k) → Roth IRA at a discount. With $382K in the Comcast 401(k) and only $50K in Roth, this is the single biggest pre-RMD tax lever the user has. No current view evaluates it.
- **Plan**: a sub-page or section that takes the 401(k) balance, projects a stair-step conversion plan up to the next tax bracket each year of the post-retirement / pre-RMD window, and shows the lifetime tax savings vs no-conversion. Simple single-bracket model first; can add multi-bracket / IRMAA later.
- **Cost**: 1–2 days.

#### V. RMD projection at 73 [P2, depends on Q]
- **Problem**: at age 73 (or 75 for those born 1960+) the IRS forces minimum distributions from traditional 401(k)/IRA. Forecasting them now lets the user see whether they'll be pushed into a higher bracket.
- **Plan**: project tax-deferred balances forward at the verdict-derived CAGR, compute year-by-year RMD using IRS Uniform Lifetime Table (published, stable), display the tax-bracket impact alongside.
- **Cost**: 1 day.

#### W. Tax-efficient location analyzer [P2, depends on Q]
- **Problem**: bonds in a Roth = wasted Roth space; growth in taxable = preventable tax drag. With account types known, we can flag misplaced holdings.
- **Plan**: a per-position "should be in [X account]" recommendation based on the holding's class (bonds → tax-deferred; high-turnover active → tax-deferred; low-turnover index → taxable; high-growth → Roth). Surface the dollar-per-year drag if mis-located.
- **Cost**: 1 day.

#### G. Dashboard concurrent fetch [P2]
- **Problem**: dashboard makes serial provider calls on cache miss (quote fan-out + macro + indices + earnings + watchlist quotes). First hit can be slow.
- **Plan**: wrap independent sections in `Thread.new`; rejoin before render. Each `safe_fetch` block is already isolated. Bound max threads to ~8.
- **Cost**: 1 day.

### Tier 3 — eventually, lower urgency

#### N. Richer empty-state when historicals fail [P2]
- When `@historical` is empty, render a panel showing each tried provider with its last status (from `HealthRegistry`); suggest waiting for cooldowns or scheduling a fetch. Half a day.

#### J. MarketDataService refactor [P3 — was P1]
- ~1,400-LOC file. Split per-provider modules along the [app/providers/](app/providers/) pattern. Pure tech debt — only do this if a feature forces the issue. 1–2 days.

#### O. Multi-broker importer [P3]
- Extract a `BrokerImporter` interface; refactor `FidelityImporter` to implement it; add per-broker parsers as we need them. Only worth doing if a non-Fidelity broker enters the picture. 1 day per additional broker.

#### P. EDGAR filings panel on /analysis [P3]
- Wire `Providers::EdgarService.recent_filings` (already implemented) into `/analysis/:symbol`. Needs a ticker→CIK mapping (SEC publishes one). 1 day.

#### H. Backtest framework — single-strategy MVP [P3 — was P2]
- Pure-Ruby walk-forward simulator. Less retirement-decision value for a target-date-fund portfolio; downgraded but kept for research interest. 2 days.

---

## Dropped

Recorded so the choice is visible:

- **Monte Carlo simulation** — GBM fan charts have thin tails, no regime modelling. Looks impressive, financially misleading.
- **Options visualizations** — Polygon free tier is end-of-day only, makes any options UX stale.
- **CoinGecko crypto** — out of scope unless explicitly wanted.
- **Alpha Vantage technical indicators** — local compute is the right answer; AV's 25 req/day budget is better spent on quote fallbacks.
- **§5.3 expanded test coverage as a standalone task** — happens organically with features.
- **L. Sector treemap** (was P3) — superseded by the asset-class breakdown shipped in PR #14. Sector colour-by-% is aesthetic; the grouped table answers the same question more directly.
- **K. Efficient frontier / Markowitz optimization** (was P3) — academic for a portfolio dominated by target-date and balanced funds where the mean-variance frame doesn't apply cleanly. Would push the user toward decisions Markowitz can't actually defend.
- **I. News sentiment scoring** (was P2) — low marginal value for a long-horizon retirement portfolio whose decisions are tax / allocation / glide-path, not headline-driven.
- **Multi-user / paid-product pivot** (considered 2026-04-30) — explicitly abandoned; app stays a single-user personal tool. Kept as a memory entry so it isn't accidentally re-proposed.

Items also resolved through earlier PRs:
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
