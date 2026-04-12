.PHONY: run dev test install refresh-cache

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
