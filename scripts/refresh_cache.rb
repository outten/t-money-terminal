#!/usr/bin/env ruby
# scripts/refresh_cache.rb
# Bust the MarketDataService cache so the next request fetches fresh data.
# Usage: bundle exec ruby scripts/refresh_cache.rb
#        or: make refresh-cache

$LOAD_PATH.unshift File.expand_path('../app', __dir__)
require 'dotenv/load'
require 'market_data_service'

MarketDataService.bust_cache!
puts "Cache cleared at #{Time.now}. Next request will fetch fresh data from Alpha Vantage."
