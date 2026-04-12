## Why

The development workflow requires manually restarting the server after every code change, slowing iteration. Additionally, the app currently falls back to static mock data instead of fetching live prices from Alpha Vantage, which means the terminal displays stale, fictional numbers despite a valid API key being configured.

## What Changes

- Add a `make dev` Makefile target that wraps Sinatra with `rerun` for file-watch-triggered auto-reload during development
- Remove the mock data fallback from `MarketDataService` so the app always fetches live quotes from Alpha Vantage when an API key is present
- Add a clear startup error/warning when `ALPHA_VANTAGE_API_KEY` is missing so the failure mode is explicit rather than silent

## Capabilities

### New Capabilities
- `dev-server`: Auto-reloading development server via `rerun`; `make dev` starts the app with file-watching enabled

### Modified Capabilities
- `market-data-integration`: Live Alpha Vantage data is now the primary path; mock fallback is restricted to test environments or when the API key is explicitly absent, and the app logs a warning when falling back

## Impact

- `Makefile` — add `dev` target
- `app/market_data_service.rb` — enforce live data path, tighten fallback logic
- `app/main.rb` — optionally add startup warning when API key is missing
- `Gemfile` / `Gemfile.lock` — `rerun` already present, just needs wiring
- No breaking API changes; existing `make run` target unchanged
