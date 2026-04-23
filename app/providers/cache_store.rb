require 'json'
require 'time'
require 'fileutils'

module Providers
  # Minimal hierarchical disk cache for provider modules.
  #
  # Files live at: <repo>/data/cache/<namespace>/<safe_key>.json
  # Envelope: { "data" => <value>, "cached_at" => <iso8601> }
  #
  # Freshness is determined by the file's mtime against a caller-supplied TTL,
  # matching the strategy used by MarketDataService for its own hierarchical cache.
  module CacheStore
    CACHE_ROOT = File.expand_path('../../../data/cache', __FILE__).freeze

    module_function

    def path(namespace, key)
      dir = File.join(CACHE_ROOT, namespace.to_s)
      FileUtils.mkdir_p(dir) unless test_env?
      safe = key.to_s.gsub(/[^A-Za-z0-9_.\-]/, '_')
      File.join(dir, "#{safe}.json")
    end

    def read(namespace, key, ttl:)
      # In tests we never want to read from real on-disk caches that were
      # produced by earlier integration runs — that would silently short-circuit
      # HTTP stubs and give false positives/negatives.
      return nil if test_env?

      file = path(namespace, key)
      return nil unless File.exist?(file)
      return nil if (Time.now - File.mtime(file)) > ttl

      payload = JSON.parse(File.read(file))
      payload['data']
    rescue StandardError
      nil
    end

    def write(namespace, key, value)
      return value if test_env?

      file = path(namespace, key)
      File.write(file, JSON.generate('data' => value, 'cached_at' => Time.now.iso8601))
      value
    rescue StandardError => e
      warn "[Providers::CacheStore] write failed for #{namespace}/#{key}: #{e.message}"
      value
    end

    def delete(namespace, key)
      file = path(namespace, key)
      File.delete(file) if File.exist?(file)
    rescue StandardError
      nil
    end

    def cached_at(namespace, key)
      file = path(namespace, key)
      File.exist?(file) ? File.mtime(file) : nil
    end

    def test_env?
      ENV['RACK_ENV'] == 'test'
    end
  end

  # Simple in-process throttle to enforce a minimum interval between outbound
  # calls to a given API. Thread-safe. Used by rate-limited providers.
  class Throttle
    def initialize(min_interval)
      @min_interval = min_interval.to_f
      @last         = nil
      @mutex        = Mutex.new
    end

    def wait!
      return if @min_interval <= 0
      return if ENV['RACK_ENV'] == 'test'

      @mutex.synchronize do
        if @last
          delta = Time.now - @last
          sleep(@min_interval - delta) if delta < @min_interval
        end
        @last = Time.now
      end
    end
  end
end
