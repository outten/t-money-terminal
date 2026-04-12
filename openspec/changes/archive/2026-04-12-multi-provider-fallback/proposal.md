## Why

Alpha Vantage's free tier caps at 25 API calls per day, causing empty responses when the quota is exceeded — the app then silently falls back to stale mock data. Adding Finnhub (already API-key-configured) and Yahoo Finance (no key required) as ordered fallbacks ensures real market data is retrieved even when Alpha Vantage is unavailable or rate-limited.

## What Changes

- `MarketDataService` gains a provider chain: **Alpha Vantage → Finnhub → Yahoo Finance → mock**
- Each provider is tried in order; the first to return a valid non-empty quote wins
- Finnhub API key loaded from `.env` (`FINNHUB_API_KEY`)
- Yahoo Finance fetched via its public `v8/finance/chart` JSON endpoint (no key required)
- Warning messages updated to indicate which provider succeeded or failed
- Response normalization: all providers map their response to the same internal hash keys (`05. price`, `10. change percent`, `06. volume`) so downstream code (`enrich_quote`, `RecommendationService`) requires no changes

## Capabilities

### New Capabilities
- `provider-fallback-chain`: Ordered multi-provider quote fetching with per-provider normalization and fallback logic

### Modified Capabilities
- `market-data-integration`: The primary fetch path now attempts three live providers before falling back to mock; requirement changes to reflect the ordered chain and per-provider warning behavior

## Impact

- `app/market_data_service.rb` — add `fetch_from_finnhub`, `fetch_from_yahoo`, refactor `fetch_quote` into provider chain
- `.env` — `FINNHUB_API_KEY` must be present for Finnhub provider to activate
- No Gemfile changes needed (`net/http` + `json` already available; Yahoo Finance uses standard HTTPS)
- `spec/services_spec.rb` — new tests for provider chain ordering
- No view, route, or CSS changes required
