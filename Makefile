.PHONY: run dev serve test install refresh-cache refresh-providers refresh-all refresh-symbol cache-status check-alerts scheduler

install:
	bundle install

# Auto-reloading dev server. `rerun` reads .rerun in the project root for
# watch dirs, file patterns, and ignore globs. NOTE: .rerun does NOT support
# `#` comments — its contents are shell-split verbatim, so any `#` becomes a
# literal token (and any prose with quotes/punctuation can be misparsed as
# options). Keep .rerun option-only; document choices here instead:
#   --dir app,views,public,scripts   only watch source directories
#   --pattern *.{rb,erb,js,css,...}  narrower than rerun's default; ignores .md
#   --ignore data/* tmp/* .cache/*   skip cache + state writes (no thrashing)
# `make dev` is an alias kept for muscle memory.
run dev:
	bundle exec rerun 'ruby app/main.rb'

# Plain server with no auto-reload — rare, e.g. when profiling startup time.
serve:
	bundle exec ruby app/main.rb

test:
	bundle exec rspec

# Refresh quotes / analyst / profiles / historicals for the full universe:
# REGIONS + portfolio + watchlist + extensions (i.e. every symbol the user
# has shown interest in). Pass a list of tickers to refresh only those.
refresh-cache:
	bundle exec ruby scripts/refresh_cache.rb

# Warm the provider caches (FMP fundamentals, FRED macro, Stooq indices,
# Finnhub/NewsAPI news) over the same universe as refresh-cache.
# Pass OPTS="--options" to also warm Polygon options chains (slow, 13s/call).
# EDGAR is not refreshed here — no view consumes it yet.
refresh-providers:
	bundle exec ruby scripts/refresh_providers.rb $(OPTS)

# Full warm-up of every cache the app actually uses, over the user's full
# symbol universe. Run this after a new Fidelity import (or nightly via cron)
# so /portfolio + /analysis pages render without firing providers.
refresh-all: refresh-cache refresh-providers

# Refresh a single symbol: make refresh-symbol SYMBOL=AAPL
refresh-symbol:
	bundle exec ruby scripts/refresh_cache.rb $(SYMBOL)
	bundle exec ruby scripts/refresh_providers.rb $(SYMBOL)

cache-status:
	bundle exec ruby scripts/cache_status.rb

# Evaluate all active price alerts. Schedule via cron for periodic checks:
#   */15 9-16 * * 1-5  cd /path/to/t-money-terminal && make check-alerts
check-alerts:
	bundle exec ruby scripts/check_alerts.rb

# Tiered cache refresh dispatcher. Pass TIER=<name>:
#   make scheduler TIER=quotes
#   make scheduler TIER=fundamentals
#   make scheduler TIER=analyst
#   make scheduler TIER=macro
#   make scheduler TIER=alerts
#   make scheduler TIER=all
# See scripts/scheduler.rb for cron / launchd installation examples.
scheduler:
	bundle exec ruby scripts/scheduler.rb --tier=$(TIER) $(OPTS)
