#!/usr/bin/env ruby
# scripts/check_alerts.rb — iterate every active price alert, fetch the current
# quote for that symbol, and flip `triggered_at` when the threshold is crossed.
#
# Run from cron (or `make check-alerts`). Safe to invoke repeatedly; triggered
# alerts are skipped on subsequent runs. Triggered alerts are appended to
# `data/alerts_triggered.log` as newline-delimited JSON for tail / email hooks.

$LOAD_PATH.unshift(File.expand_path('../../app', __FILE__))

require 'dotenv'
Dotenv.load(File.expand_path('../../.credentials', __FILE__))

require 'alerts_store'
require 'market_data_service'
require 'notifiers'

active = AlertsStore.active
if active.empty?
  puts '[check_alerts] No active alerts.'
  exit 0
end

channels = Notifiers.configured_channels
if channels.empty?
  puts '[check_alerts] No notification channels configured. Triggered alerts will only land in data/alerts_triggered.log.'
  puts '              Set ALERT_WEBHOOK_URL, ALERT_NTFY_TOPIC, or ALERT_EMAIL_TO + ALERT_SMTP_* in .credentials to enable delivery.'
else
  puts "[check_alerts] Notification channels: #{channels.join(', ')}"
end

puts "[check_alerts] Evaluating #{active.length} active alert(s)…"

active.each do |alert|
  symbol    = alert[:symbol]
  condition = alert[:condition]
  threshold = alert[:threshold].to_f

  quote = MarketDataService.quote(symbol) rescue nil
  price = quote && (quote['05. price'] || quote[:price])
  price = price.to_f
  if price <= 0
    puts "  #{symbol}: could not resolve price — skipping."
    next
  end

  AlertsStore.record_price(alert[:id], price)

  triggered =
    (condition == 'above' && price >= threshold) ||
    (condition == 'below' && price <= threshold)

  if triggered
    fired = AlertsStore.mark_triggered(alert[:id], price) || alert.merge(last_price: price, triggered_at: Time.now.utc.iso8601)
    puts "  ✔ TRIGGERED  #{symbol}  #{condition} #{threshold.round(2)}  (now $#{price.round(2)})"
    Notifiers.dispatch(fired).each do |result|
      if result[:ok]
        puts "    → notified via #{result[:channel]}"
      else
        warn "    ! #{result[:channel]} failed: #{result[:error]}"
      end
    end
  else
    puts "  · quiet      #{symbol}  #{condition} #{threshold.round(2)}  (now $#{price.round(2)})"
  end
end

puts '[check_alerts] Done.'
