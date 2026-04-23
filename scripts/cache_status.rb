#!/usr/bin/env ruby
# scripts/cache_status.rb
#
# Print a summary of the on-disk + in-memory cache state.
# Shows both the hierarchical cache structure and monolithic cache stats.
# Does NOT start the web server — reads the cache files directly.
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

# Show hierarchical cache directory stats
cache_dir = MarketDataService::CACHE_DIR
hierarchical_files = Dir.glob(File.join(cache_dir, '**', '*.json'))

puts
puts "=" * 90
puts "CACHE STATUS REPORT"
puts "=" * 90
puts
puts "Hierarchical Cache Directory: #{cache_dir}"
if hierarchical_files.any?
  total_size_kb = hierarchical_files.sum { |f| File.size(f) } / 1024.0
  puts "  Files: #{hierarchical_files.length} (#{total_size_kb.round(1)} KB total)"
  
  # Group by subdirectory
  %w[quotes historical analyst profiles].each do |subdir|
    subdir_files = hierarchical_files.select { |f| f.include?("/#{subdir}/") }
    next if subdir_files.empty?
    subdir_size_kb = subdir_files.sum { |f| File.size(f) } / 1024.0
    puts "    #{subdir.ljust(12)}: #{subdir_files.length.to_s.rjust(3)} files (#{subdir_size_kb.round(1)} KB)"
  end
else
  puts "  (No hierarchical cache files found)"
end
puts

# Show monolithic cache file stats (if exists)
if File.exist?(MarketDataService::CACHE_FILE)
  disk_size = (File.size(MarketDataService::CACHE_FILE) / 1024.0).round(1)
  puts "Monolithic Cache File: #{MarketDataService::CACHE_FILE} (#{disk_size} KB)"
else
  puts "Monolithic Cache File: (not found)"
end
puts

if entries.empty?
  puts "In-memory cache is empty. No entries loaded."
  exit 0
end

puts "-" * 90
puts "IN-MEMORY CACHE ENTRIES (#{entries.size} total)"
puts "-" * 90

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
