## Context

The app already uses a provider chain (Alpha Vantage → Finnhub → Yahoo Finance) for price data, and Finnhub is already authenticated via `FINNHUB_API_KEY`. Finnhub's free tier provides:
- `/stock/recommendation` — monthly analyst consensus (strong buy, buy, hold, sell, strong sell counts)
- `/stock/profile2` — company/ETF name, description, exchange, industry, market cap, IPO date, logo URL
- `/stock/candle` — OHLCV candlestick historical data (requires resolution + from/to Unix timestamps)
- `/quote` — real-time quote already used in provider chain

Chart.js is already loaded via CDN. The 24-hour cache on `MarketDataService` applies to all new data types.

Note: ETFs (EWJ, VGK, SPY) have limited `profile2` data from Finnhub. Yahoo Finance's chart endpoint provides better historical coverage and is used as fallback for candles.

## Goals / Non-Goals

**Goals:**
- Embed BUY/SELL/HOLD + analyst counts + price data in the Dashboard, symbol-linked to Analysis pages
- Analysis page is a complete per-symbol research view: analysts, profile, financials, historical charts, source links
- All data sections cite their source (Finnhub, Yahoo Finance, Alpha Vantage)
- Historical chart supports period toggle (1D, 1M, 3M, YTD, 1Y, 5Y) rendered via Chart.js
- Remove the `/recommendations` standalone page cleanly

**Non-Goals:**
- Real-time streaming prices (WebSocket) — 24h cache is sufficient for this terminal
- User watchlists or custom symbol search
- Paid API endpoints (Finnhub free tier only)
- Mobile-first responsive redesign

## Decisions

### Analyst consensus signal
Finnhub `recommendation` endpoint returns the 3 most recent monthly snapshots. We use the most recent month. Signal derived: if `strongBuy + buy > strongSell + sell + hold/2`, signal is BUY; if `strongSell + sell > strongBuy + buy + hold/2`, signal is SELL; otherwise HOLD. This replaces the naive price-change-% approach.

For ETFs (SPY, EWJ, VGK), Finnhub returns empty analyst data — fall back to the existing price-change-% logic in that case, labeled clearly as "momentum signal" rather than "analyst consensus."

### Historical data source
Finnhub candles (`/stock/candle`) work for US equities. Yahoo Finance `v8/finance/chart` provides `timestamp` + `close` arrays for any symbol and supports `range` parameters (1d, 1mo, 3mo, ytd, 1y, 5y) without a key — preferred for simplicity and ETF coverage. Use Yahoo as primary for candles, Finnhub as fallback.

### Dashboard embedding
The Dashboard becomes the landing page for recommendations. The existing summary table stays at the top; below it, a "Market Signals" section shows a card per symbol with signal badge, price, change, analyst counts summary, and a "View Analysis →" link.

### Cache keys
New cache entries keyed as `"analyst:#{symbol}"`, `"profile:#{symbol}"`, `"candle:#{symbol}:#{period}"` alongside existing quote cache. All share the 24h TTL.

### Routing
`GET /analysis/:symbol` — validates symbol is in the known `REGIONS` symbol list (or a small allowlist) to prevent open-ended API calls with user-supplied input. Returns 404 for unknown symbols.

`GET /recommendations` → 301 redirect to `/dashboard` to handle any existing bookmarks.

## Risks / Trade-offs

- [Finnhub free tier rate limit: 60 calls/minute] → 24h cache means cold start fires at most ~15 calls (5 quotes + 5 analyst + 5 profile); well within limits
- [ETF profile data sparse on Finnhub] → Supplement with hardcoded descriptions for SPY/EWJ/VGK as known ETFs; clearly labeled
- [Yahoo Finance candle endpoint may change] → Wrapped in rescue with a "Historical data unavailable" graceful UI state
- [Analysis page latency on first load] → All three data types (quote, analyst, profile) fetched sequentially on first miss; acceptable as a one-time cold-cache cost per symbol per day
