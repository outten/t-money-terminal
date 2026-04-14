.PHONY: run dev test install refresh-cache refresh-symbol cache-status

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

# Refresh a single symbol: make refresh-symbol SYMBOL=AAPL
refresh-symbol:
	bundle exec ruby scripts/refresh_cache.rb $(SYMBOL)

cache-status:
	bundle exec ruby scripts/cache_status.rb
