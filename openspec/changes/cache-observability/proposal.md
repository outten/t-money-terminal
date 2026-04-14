## Why

The disk cache lives at `tmp/market_cache.json` — a path that is gitignored, not documented in the UI, and not surfaced anywhere in the app or Makefile. Developers and operators have no way to inspect cache health, see what is cached, or understand how stale the data is without reading source code or manually poking at JSON files. This slows troubleshooting and makes the caching architecture opaque.

## What Changes

- Add a `GET /admin/cache` page in the web app showing a human-readable table of every cached key: data type, cached timestamp, staleness, and data size
- Add `make cache-status` Makefile target that prints a summary of the disk cache to the terminal (key count, file size, oldest/newest entry)
- Update the footer or a visible location in the app to show the age of the most recently cached data so users know how fresh the dashboard data is
- Add the cache file path to startup logs so it is easy to find when the server boots

## Capabilities

### New Capabilities
- `cache-status-page`: A `/admin/cache` web page showing cache contents, timestamps, staleness by key, and a button to clear all caches

### Modified Capabilities
- `makefile-support`: Add `cache-status` target that reports on the disk cache without starting the server

## Impact

- `app/main.rb`: New `GET /admin/cache` route
- New view: `views/admin_cache.erb`
- `Makefile`: New `cache-status` target
- `app/market_data_service.rb`: Expose a `cache_summary` class method returning structured cache metadata
- No changes to existing cache behavior — read-only observability only
