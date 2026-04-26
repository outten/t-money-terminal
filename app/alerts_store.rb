require 'json'
require 'fileutils'
require 'securerandom'

# AlertsStore — file-backed price-threshold alerts persisted at
# `data/alerts.json`. Each alert is:
#
#   { id:, symbol:, condition: 'above'|'below', threshold:, created_at:,
#     triggered_at: (nil until fired), last_price: (nil until checked) }
#
# `scripts/check_alerts.rb` reads the active list, fetches the current quote
# for each symbol, and flips `triggered_at` when the condition matches.
# Triggered alerts are appended to `data/alerts_triggered.log` for UI display.
module AlertsStore
  DEFAULT_PATH = File.expand_path('../../data/alerts.json',          __FILE__)
  LOG_PATH     = File.expand_path('../../data/alerts_triggered.log', __FILE__)
  MUTEX        = Mutex.new
  VALID_CONDITIONS = %w[above below].freeze

  module_function

  def path
    ENV['ALERTS_PATH'] || DEFAULT_PATH
  end

  def log_path
    ENV['ALERTS_LOG_PATH'] || LOG_PATH
  end

  # Returns the raw list of alert hashes (symbol keys).
  def read
    return [] unless File.exist?(path)
    raw = File.read(path)
    return [] if raw.strip.empty?
    parsed = JSON.parse(raw)
    return [] unless parsed.is_a?(Array)
    parsed.map { |h| symbolize(h) }
  rescue JSON::ParserError
    []
  end

  # Active (not yet triggered) alerts only.
  def active
    read.reject { |a| a[:triggered_at] }
  end

  # Add a new alert. Returns the created alert hash (with generated id).
  # Raises ArgumentError on invalid input.
  def add(symbol:, condition:, threshold:)
    sym = symbol.to_s.strip.upcase
    raise ArgumentError, 'symbol required' if sym.empty?

    cond = condition.to_s.strip.downcase
    raise ArgumentError, "condition must be 'above' or 'below'" unless VALID_CONDITIONS.include?(cond)

    thr = Float(threshold) rescue nil
    raise ArgumentError, 'threshold must be a positive number' if thr.nil? || thr <= 0

    alert = {
      id:           SecureRandom.hex(6),
      symbol:       sym,
      condition:    cond,
      threshold:    thr,
      created_at:   Time.now.utc.iso8601,
      triggered_at: nil,
      last_price:   nil
    }

    MUTEX.synchronize do
      list = read_unlocked << alert
      write_unlocked(list)
    end
    alert
  end

  def remove(id)
    MUTEX.synchronize do
      list = read_unlocked.reject { |a| a[:id] == id.to_s }
      write_unlocked(list)
      list
    end
  end

  # Mark an alert as triggered. Appends to the triggered log.
  def mark_triggered(id, price)
    MUTEX.synchronize do
      list = read_unlocked
      alert = list.find { |a| a[:id] == id.to_s }
      return nil unless alert

      alert[:triggered_at] = Time.now.utc.iso8601
      alert[:last_price]   = price.to_f
      write_unlocked(list)
      append_log(alert)
      alert
    end
  end

  # Record the latest observed price without triggering.
  def record_price(id, price)
    MUTEX.synchronize do
      list = read_unlocked
      alert = list.find { |a| a[:id] == id.to_s }
      return nil unless alert
      alert[:last_price] = price.to_f
      write_unlocked(list)
      alert
    end
  end

  # --- internals -----------------------------------------------------------

  def read_unlocked
    return [] unless File.exist?(path)
    raw = File.read(path)
    return [] if raw.strip.empty?
    parsed = JSON.parse(raw)
    return [] unless parsed.is_a?(Array)
    parsed.map { |h| symbolize(h) }
  rescue JSON::ParserError
    []
  end

  def write_unlocked(list)
    FileUtils.mkdir_p(File.dirname(path))
    tmp = "#{path}.tmp"
    File.write(tmp, JSON.pretty_generate(list))
    File.rename(tmp, path)
  end

  def symbolize(h)
    return {} unless h.is_a?(Hash)
    h.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
  end

  def append_log(alert)
    FileUtils.mkdir_p(File.dirname(log_path))
    File.open(log_path, 'a') do |f|
      f.puts JSON.generate(alert)
    end
  end
end
