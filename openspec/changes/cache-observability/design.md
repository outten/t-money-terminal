## Context

`MarketDataService` writes all fetched data to `tmp/market_cache.json` via `save_to_disk` on every `store_cache` call. The file is loaded once at class load time. Neither the file path nor the cache state is exposed anywhere in the app UI, server logs, or CLI tooling. Developers debugging data freshness issues must find the constant in source, locate the file manually, and parse JSON by hand.

The cache holds three types of entries keyed by string:
- Quote entries (key = symbol, e.g. `"AAPL"`)
- Analyst recommendation entries (key = `"analyst:SYMBOL"`)
- Company profile entries (key = `"profile:SYMBOL"`)
- Historical price entries (key = `"candle:SYMBOL:PERIOD"`)

Per-key timestamps are stored in `@cache_timestamps` alongside the data.

## Goals / Non-Goals

**Goals:**
- Make the cache file path visible at server startup
- Provide a `GET /admin/cache` page listing all keys with type, timestamp, staleness, and entry count/size
- Add `make cache-status` script that prints a terminal summary without starting the server
- Expose a `MarketDataService.cache_summary` method to support both the web page and the CLI tool

**Non-Goals:**
- Authentication on the `/admin/cache` route (this is a local dev/ops tool, not a production admin panel)
- Editing or modifying cache entries through the UI
- Real-time auto-refresh of the cache status page

## Decisions

### `cache_summary` class method on `MarketDataService`

**Decision**: Add a read-only `cache_summary` class method that returns a structured array of hashes, one per cache key, with fields: `key`, `type`, `symbol`, `period`, `cached_at`, `is_stale`, `size` (entry count for arrays, key count for hashes).

This gives both the web route and the CLI script a single source of truth without duplicating logic.

Alternatives considered:
- Read `tmp/market_cache.json` directly from the CLI script: simpler but bypasses in-memory state and is fragile if the key schema changes.

### Separate `scripts/cache_status.rb` for the CLI target

**Decision**: Add a thin `scripts/cache_status.rb` that requires `MarketDataService`, calls `cache_summary`, and pretty-prints to stdout. This keeps the Makefile target simple (`bundle exec ruby scripts/cache_status.rb`) and matches the existing `scripts/refresh_cache.rb` pattern.

### Footer data-age indicator

**Decision**: Pass the oldest non-stale `@cache_timestamps` value to every layout render and display it in the footer as "Data as of HH:MM". This gives end-users immediate feedback without requiring they navigate to `/admin/cache`.

The timestamp is computed in a helper and passed via a `before` filter in `app/main.rb` to `@cache_updated_at`.

## Risks / Trade-offs

- **`/admin/cache` is unauthenticated** → Mitigation: acceptable for a local dev tool; note in docs that it should be disabled or protected before any public deployment
- **Footer timestamp adds a `MarketDataService` call to every request** → Mitigation: `cache_summary` only reads in-memory state (no I/O), so the overhead is negligible
