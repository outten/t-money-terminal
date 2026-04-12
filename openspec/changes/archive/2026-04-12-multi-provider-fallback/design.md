## Context

`MarketDataService` currently has a single live provider (Alpha Vantage) with a direct fallback to static mock data. Alpha Vantage's free tier limits to 25 API calls/day; once exhausted every request returns an empty `Global Quote` object. The app then falls back to stale mock prices, which defeats the purpose of live data. Two additional providers are available: Finnhub (user has an API key in `.env`) and Yahoo Finance (public endpoint, no key needed). Both return real-time quotes and together provide ample coverage as secondary and tertiary sources.

## Goals / Non-Goals

**Goals:**
- Try Alpha Vantage → Finnhub → Yahoo Finance in order; use the first that returns a valid quote
- Normalize all three provider responses to the same internal hash shape so callers need no changes
- Emit a targeted `warn` when a provider is skipped, naming which one failed and why
- Keep the mock fallback as the final safety net for fully offline or test scenarios

**Non-Goals:**
- Round-robin or load-balancing across providers (ordered priority only)
- Persistent provider-selection state between requests
- Caching per-provider (the existing 24h unified cache is unchanged)
- Adding any new Gemfile dependencies (pure `net/http` + `json`)

## Decisions

### Provider response normalization
Each provider returns differently shaped JSON. We normalize into a shared internal shape using string keys that match the existing Alpha Vantage field names (`"05. price"`, `"10. change percent"`, `"06. volume"`). This keeps `enrich_quote` and `RecommendationService` completely unchanged.

**Alpha Vantage** already returns these keys natively.  
**Finnhub** `/quote` endpoint returns `{ c: current_price, dp: change_percent, ... }` — mapped to the shared keys.  
**Yahoo Finance** `v8/finance/chart/<symbol>` returns `{ chart: { result: [{ meta: { regularMarketPrice, regularMarketChangePercent, regularMarketVolume } }] } }` — mapped to the shared keys.

### Provider chain implementation
`fetch_quote` becomes an iterator over an ordered array of `[method_name, condition]` tuples. Each attempt is wrapped in a rescue so a single provider failure never bubbles up. The first non-nil, non-empty result is cached and returned.

This is simpler than a Strategy pattern for three providers — a class-per-provider abstraction would be over-engineering for this scale.

### `.env` vs `.credentials`
The existing `ALPHA_VANTAGE_API_KEY` lives in `.credentials`. The user added `FINNHUB_API_KEY` to `.env`. We load both files at service boot so both keys are available. Yahoo Finance needs no key.

## Risks / Trade-offs

- [Yahoo Finance's unofficial API endpoint changes without notice] → It has been stable for years; if it breaks, mock data is the final fallback and a warning is emitted
- [Three sequential HTTP calls on cache miss increases latency] → Only happens on first load or after `make refresh-cache`; 24h cache means this is rare
- [Finnhub `dp` field is percentage already (e.g. `-0.52`), not pre-formatted like Alpha Vantage's `"-0.5234%"`] → Normalization layer appends `%` when formatting Finnhub's value for display consistency
