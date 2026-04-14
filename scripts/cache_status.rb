#!/usr/bin/env ruby
# scripts/cache_status.rb
#
# Print a summary of the on-disk + in-memory cache state.
# Does NOT start the web server — reads the cache file directly.
#
# Usage:
#   bundle exec ruby scripts/cache_status.rb
#   make cache-status

$LOAD_PATH.unshift File.expand_path('../app', __dir__)

require 'dotenv'
Dotenv.load(
  File.expand_path('../.env',         __dir__),
  File.expand_path('../.credentials', __dir__)
)
require 'market_data_service'

entries = MarketDataService.cache_summary

if entries.empty?
  puts "Cache is empty. No entries found."
  puts "Disk cache path: #{MarketDataService::CACHE_FILE}"
  exit 0
end

disk_size = File.exist?(MarketDataService::CACHE_FILE) \
            ? "#{(File.size(MarketDataService::CACHE_FILE) / 1024.0).round(1)} KB" \
            : '(file not found)'

puts "Cache Status — #{entries.size} entries | Disk: #{MarketDataService::CACHE_FILE} (#{disk_size})"
puts '-' * 90

col_widths = { key: 32, type: 9, symbol: 7, period: 7, cached_at: 22, status: 6, size: 5 }
header  = format("%-#{col_widths[:key]}s %-#{col_widths[:type]}s %-#{col_widths[:symbol]}s %-#{col_widths[:period]}s %-#{col_widths[:cached_at]}s %-#{col_widths[:status]}s %#{col_widths[:size]}s",
                 'Key', 'Type', 'Symbol', 'Period', 'Cached At', 'Status', 'Size')
puts header
puts '-' * 90

entries.each do |e|
  ts_str = e[:cached_at] ? e[:cached_at].strftime('%Y-%m-%d %H:%M:%S %Z') : '—'
  status = e[:is_stale] ? 'stale' : 'fresh'
  puts format("%-#{col_widths[:key]}s %-#{col_widths[:type]}s %-#{col_widths[:symbol]}s %-#{col_widths[:period]}s %-#{col_widths[:cached_at]}s %-#{col_widths[:status]}s %#{col_widths[:size]}d",
              e[:key][0, col_widths[:key]],
              e[:type],
              e[:symbol] || '—',
              e[:period] || '—',
              ts_str,
              status,
              e[:size])
end

puts '-' * 90
stale_count = entries.count { |e| e[:is_stale] }
fresh_count = entries.size - stale_count
puts "#{fresh_count} fresh, #{stale_count} stale"
