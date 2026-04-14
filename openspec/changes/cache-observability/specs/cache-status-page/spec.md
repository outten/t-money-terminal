## ADDED Requirements

### Requirement: Expose cache summary via class method
`MarketDataService` SHALL provide a `cache_summary` class method that returns an array of hashes, one per cached key, with the fields: `key` (String), `type` (one of `quote`, `analyst`, `profile`, `candle`, `other`), `symbol` (String or nil), `period` (String or nil), `cached_at` (Time or nil), `is_stale` (Boolean), and `size` (Integer — number of array elements or hash keys in the cached entry).

#### Scenario: Summary includes all cached entries
- **WHEN** the cache holds quote, analyst, profile, and candle entries
- **THEN** `cache_summary` returns one hash per key with the correct `type` derived from the key prefix

#### Scenario: Stale detection uses the same TTL as the service
- **WHEN** a cached entry's timestamp is older than the service cache TTL
- **THEN** the corresponding `is_stale` field is `true`

#### Scenario: Empty cache returns empty array
- **WHEN** no entries have been stored
- **THEN** `cache_summary` returns `[]`

### Requirement: Provide a cache status admin page
The system SHALL expose a `GET /admin/cache` route that renders an HTML page listing all current cache entries, their types, timestamps, staleness status, and entry size. The route SHALL be unauthenticated and intended for local/development use only.

#### Scenario: Page renders with populated cache
- **WHEN** the user visits `/admin/cache` and the cache contains entries
- **THEN** the response is 200 and each entry is listed with its key, type, timestamp, staleness indicator, and size

#### Scenario: Page renders with empty cache
- **WHEN** the user visits `/admin/cache` and no entries have been cached
- **THEN** the response is 200 and the page shows an empty-state message

### Requirement: Display data freshness indicator in the site footer
The layout SHALL display a "Data as of HH:MM" line in the footer reflecting the timestamp of the most recently updated non-stale cache entry. When no non-stale entries exist, the indicator is omitted.

#### Scenario: Footer shows freshness time when cache is populated
- **WHEN** the user views any page and the cache contains at least one non-stale entry
- **THEN** the footer displays "Data as of HH:MM" using the local time of the newest entry

#### Scenario: Footer omits freshness when cache is empty or all entries are stale
- **WHEN** all cached entries are stale or the cache is empty
- **THEN** the footer does not display a data freshness indicator

### Requirement: Log cache file path at server startup
The system SHALL log the absolute path of `tmp/market_cache.json` and whether it was loaded successfully (including entry count) when the server starts.

#### Scenario: Cache file found at startup
- **WHEN** `tmp/market_cache.json` exists and is valid JSON
- **THEN** the startup log includes the file path and the number of entries loaded

#### Scenario: Cache file absent at startup
- **WHEN** `tmp/market_cache.json` does not exist
- **THEN** the startup log notes that no disk cache was found and the service starts with an empty in-memory cache
