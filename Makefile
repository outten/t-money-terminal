.PHONY: run dev test install refresh-cache refresh-providers refresh-all refresh-symbol cache-status

install:
	bundle install

run:
	bundle exec ruby app/main.rb

dev:
	bundle exec rerun 'ruby app/main.rb'

test:
	bundle exec rspec

refresh-cache:
	bundle exec ruby scripts/refresh_cache.rb

# Warm the new provider caches (FMP, FRED, News, Stooq)
# Pass OPTS="--options" to also warm Polygon options chains (slow, 13s/call).
refresh-providers:
	bundle exec ruby scripts/refresh_providers.rb $(OPTS)

# Full warm-up: core market data + provider caches.
refresh-all: refresh-cache refresh-providers

# Refresh a single symbol: make refresh-symbol SYMBOL=AAPL
refresh-symbol:
	bundle exec ruby scripts/refresh_cache.rb $(SYMBOL)
	bundle exec ruby scripts/refresh_providers.rb $(SYMBOL)

cache-status:
	bundle exec ruby scripts/cache_status.rb
