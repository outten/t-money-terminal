## Context

The dashboard currently shows a fixed hardcoded list of ~5–8 symbols with a minimal table: symbol, region, price, change, and a simple signal. There are no region-specific sub-pages, no symbol type classification, and the signal is a binary categorical label from `RecommendationService#signal`. The analysis page fetches a Finnhub profile (which includes `weburl`) but does not render a homepage link.

Key constraints:
- Alpha Vantage free tier: 25 req/day, 5 req/min
- Finnhub free tier: rate limits per minute; candle endpoint is premium (unavailable)
- Yahoo Finance: 429 rate-limiting on dev IPs without crumb auth
- Disk cache at `tmp/market_cache.json` mitigates re-fetch pressure

## Goals / Non-Goals

**Goals:**
- Expand the tracked symbol list to a practical top-N (target 15–20) within free-tier quotas
- Add a "Type" column derived from Finnhub profile `type` field or a hardcoded map
- Make region column values clickable links to `/region/:name` pages
- Build `/region/:name` pages that re-use the same enriched table, filtered by region
- Replace the binary signal with a weighted-average score across analyst buy/hold/sell counts
- Render company homepage URL (from Finnhub `weburl`) on the analysis page when available

**Non-Goals:**
- Dynamic symbol discovery (no screener API integration)
- Real-time streaming data
- User-configurable watchlists
- Pagination of the symbol table

## Decisions

### Symbol count: target 15–20

**Decision**: Expand from ~8 to 15–20 symbols.

AV allows 25 req/day free. At one quote call per symbol per day the refresh script would consume ~20 of those; leaving margin for historical prefetch calls. A fixed list of 15–20 gives users a materially richer dashboard without exhausting API quotas. Finnhub quote calls do not count toward the AV quota, so quotes can fall back to Finnhub for symbols beyond the AV daily budget.

Alternatives considered:
- 50 symbols: exceeds AV 25 req/day unless all data comes from Finnhub quotes only; historical data would be unavailable for most symbols
- 10 symbols: safe but barely an improvement

### Symbol type: hardcoded map + Finnhub profile `type`

**Decision**: Maintain a `SYMBOL_TYPES` hash in `MarketDataService` for known ETFs and special instruments. For all other symbols, read `type` from the Finnhub profile response (values: `"EQS"` = Common Equity, `"ETF"`, etc.) and map to human labels. Hardcoded map takes precedence to avoid unnecessary API round-trips for well-known instruments.

Alternatives considered:
- Always fetch Finnhub profile: already fetched for analysis page; could reuse cached profile. This is fine for cached symbols but adds latency on cache miss.
- Use only hardcoded map: requires manual maintenance as list grows.

### Weighted-average signal score

**Decision**: Replace the threshold inequality logic (`strongBuy + buy > strongSell + sell + hold/2`) with a normalized weighted score:

```
score = (strongBuy × 2 + buy × 1 + hold × 0 + sell × −1 + strongSell × −2) / total_votes
```

BUY if score > 0.5, SELL if score < −0.5, HOLD otherwise. This gives a continuous signal that is more nuanced when analyst opinions are split. The score is exposed in the signal detail hash alongside existing `signal` and `signal_type` keys for use in views.

Alternatives considered:
- Keep existing binary threshold: simpler but loses gradation (a 40-buy/1-sell symbol gets the same label as a 2-buy/1-sell symbol)
- Simple majority vote: ignores the strength of strong-buy vs buy

### Region pages: new `/region/:name` route + shared partial

**Decision**: Add a `GET /region/:name` Sinatra route that fetches quotes for the symbols in that region and renders a new `views/region.erb` template. Extract the symbol table into a shared partial (`views/_symbol_table.erb`) reused by both dashboard and region pages.

Alternatives considered:
- Duplicate the table markup in `region.erb`: simpler but diverges over time
- Client-side filtering on dashboard: single-page approach but requires JS and would conflict with the multi-page architecture

### Homepage link: render only when `weburl` is non-empty

**Decision**: In `views/analysis.erb`, render an anchor tag pointing to the Finnhub `weburl` value only if it is present and non-blank. No additional API calls needed — profile is already fetched and cached. Link opens in a new tab with `rel="noopener noreferrer"`.

## Risks / Trade-offs

- **Symbol list expansion increases cold-start cache population time** → Mitigation: `scripts/refresh_cache.rb` handles bulk prefetch; app still serves stale cached data while warm
- **`/region/:name` with unknown region name** → Mitigation: return 404 if region name not in the known region map
- **Weighted score thresholds (±0.5) may need tuning** → Mitigation: thresholds extracted as named constants for easy adjustment
- **Finnhub profile `type` field values vary** → Mitigation: unknown types fall back to "Equity" label with a safe default, and the hardcoded map covers the most common ETFs in our list
