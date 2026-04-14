## 1. Service Layer

- [x] 1.1 Add `CACHE_FILE` constant to `MarketDataService` and replace the inline `tmp/market_cache.json` string with it throughout the class
- [x] 1.2 Add `cache_summary` class method that derives type/symbol/period from each key, looks up timestamp, computes staleness, and returns the structured array
- [x] 1.3 Log `CACHE_FILE` path and loaded entry count (or "no disk cache found") after the `load_from_disk` call in the class initializer/load block

## 2. Admin Route and View

- [x] 2.1 Add `GET /admin/cache` route in `app/main.rb` that calls `MarketDataService.cache_summary` and renders `views/admin_cache.erb`
- [x] 2.2 Create `views/admin_cache.erb` with a table showing key, type, symbol, period, cached_at, staleness badge, and size for each entry
- [x] 2.3 Add an empty-state message in `admin_cache.erb` for when the cache summary is empty

## 3. Footer Freshness Indicator

- [x] 3.1 Add a `before` filter in `app/main.rb` that computes `@cache_updated_at` (newest non-stale `cached_at` timestamp from `cache_summary`, or nil)
- [x] 3.2 Update `views/layout.erb` footer to display "Data as of HH:MM" when `@cache_updated_at` is present

## 4. CLI Script and Makefile

- [x] 4.1 Create `scripts/cache_status.rb` that requires `MarketDataService`, calls `cache_summary`, and pretty-prints a table to stdout
- [x] 4.2 Add `cache-status` target to `Makefile` that runs `bundle exec ruby scripts/cache_status.rb`

## 5. Tests

- [x] 5.1 Add `services_spec.rb` tests for `cache_summary`: empty cache returns `[]`, correct `type` derivation for each key prefix, `is_stale` set correctly based on TTL
- [x] 5.2 Add `app_spec.rb` tests for `GET /admin/cache`: returns 200 with populated cache, returns 200 with empty cache showing empty-state text
