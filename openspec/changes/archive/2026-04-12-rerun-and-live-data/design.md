## Context

The app is fully built with five pages, Alpha Vantage integration, and 24-hour caching. `rerun` is already declared in the Gemfile but not wired to any Makefile target. The `MarketDataService` will call Alpha Vantage when `ALPHA_VANTAGE_API_KEY` is set in the environment (loaded from `.credentials` via dotenv), but silently falls back to `MOCK_PRICES` on any error, including a missing key — making it opaque when live data is unavailable.

## Goals / Non-Goals

**Goals:**
- Add a `make dev` target using `rerun` so the app auto-reloads on file changes during development
- Enforce live data as the primary path in `MarketDataService` when an API key is present
- Make the fallback explicit: log a warning when falling back to mock data so developers can see what's happening

**Non-Goals:**
- Removing mock data entirely (it remains valuable for tests and API-key-less environments)
- Changing the 24-hour cache TTL or cache strategy
- Switching to a different data provider

## Decisions

### rerun invocation
`bundle exec rerun --background -- ruby app/main.rb` starts Sinatra in a subprocess that rerun watches and restarts. Alternative: `bundle exec rerun 'ruby app/main.rb'` (foreground). We'll use the foreground version (`bundle exec rerun 'ruby app/main.rb'`) because it keeps stdout/stderr directly visible in the terminal — the existing `run` target already occupies the foreground, and `dev` should match that ergonomic.

We'll watch `app/`, `views/`, `public/`, and `config.ru` patterns by default (rerun defaults to `**/*.{rb,erb,css,js}` which already covers these). No `--dir` flag needed.

### Live data enforcement
The `fetch_quote` method already branches on `API_KEY`. The change: when `API_KEY` is present and the HTTP request fails (network, rate limit, bad JSON), `warn` rather than silently swallowing, then fall back. When `API_KEY` is absent, `warn` once at startup (or at first fetch) so the developer immediately knows they're in mock mode.

We use `warn` (sends to stderr) rather than `puts` to keep it out of normal response logs.

### No changes to `make run`
`make run` stays as `bundle exec ruby app/main.rb` — no rerun wrapping — so production/CI usage is unchanged.

## Risks / Trade-offs

- [Alpha Vantage free tier is rate-limited to 25 calls/day] → With 24-hour cache the app makes at most one call per symbol per day; well within limits for the default symbol set (~5 symbols)
- [rerun polls file system and may trigger spurious reloads on macOS] → Acceptable for development use; `make run` is unaffected
- [Startup warning on missing API key adds noise in test suite] → Guard the warn behind a check that skips in test environment (`ENV['RACK_ENV'] == 'test'`)
