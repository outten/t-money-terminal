require 'time'

# HealthRegistry — in-process per-provider success/failure ring buffer.
#
# Every outbound provider call records a single observation:
#
#   HealthRegistry.record(provider: 'tiingo_quote', status: :ok,
#                         http_status: 200, latency_ms: 142)
#   HealthRegistry.record(provider: 'tiingo_quote', status: :error,
#                         reason: 'rate_limited', http_status: 429)
#
# `summary` returns aggregated stats (total / ok / error / rate of success /
# last success time / last error time + reason) over the last N observations.
# Used by `/admin/health` and the provider-health JSON API.
#
# Design notes:
# - In-memory only. The web is one Puma process; the scheduler logs separately
#   to stdout. Cross-process visibility is out of scope.
# - Bounded ring buffer (CAPACITY per provider) to keep memory flat.
# - Mutex-guarded so multiple Puma threads don't corrupt the deque.
# - No-op in test env unless `HEALTH_REGISTRY=1` so we don't pollute spec
#   output, but specs that exercise this module flip the flag explicitly.
module HealthRegistry
  CAPACITY = 100
  MUTEX    = Mutex.new

  STATUSES = %i[ok error].freeze

  @observations = Hash.new { |h, k| h[k] = [] }

  module_function

  # Record a single provider call. `status` is :ok or :error.
  def record(provider:, status:, reason: nil, http_status: nil, latency_ms: nil)
    return if disabled?
    raise ArgumentError, "status must be one of #{STATUSES.inspect}" unless STATUSES.include?(status)

    obs = {
      at:          Time.now,
      provider:    provider.to_s,
      status:      status,
      reason:      reason,
      http_status: http_status,
      latency_ms:  latency_ms
    }

    MUTEX.synchronize do
      buf = @observations[provider.to_s]
      buf << obs
      buf.shift while buf.length > CAPACITY
    end
    obs
  end

  # Wraps a block, timing it and recording either :ok or :error based on the
  # block's behavior. Returns the block's value. The block receives a small
  # context hash it can populate (e.g. ctx[:http_status] = 429) before either
  # returning or raising — exceptions are recorded as :error and re-raised.
  def measure(provider, reason_on_nil: nil)
    return yield({}) if disabled?

    ctx     = {}
    started = Time.now
    begin
      result = yield(ctx)
      latency = ((Time.now - started) * 1000).round
      status  = result.nil? ? :error : :ok
      record(
        provider:    provider,
        status:      status,
        reason:      status == :error ? (ctx[:reason] || reason_on_nil) : nil,
        http_status: ctx[:http_status],
        latency_ms:  latency
      )
      result
    rescue StandardError => e
      latency = ((Time.now - started) * 1000).round
      record(
        provider:    provider,
        status:      :error,
        reason:      "#{e.class}: #{e.message}".slice(0, 200),
        http_status: ctx[:http_status],
        latency_ms:  latency
      )
      raise
    end
  end

  # Returns an array of per-provider summary hashes:
  #   [{ provider:, total:, ok:, error:, success_rate:,
  #      last_ok_at:, last_error_at:, last_error_reason:,
  #      last_http_status:, avg_latency_ms: }, ...]
  def summary
    snapshot = MUTEX.synchronize { @observations.transform_values(&:dup) }
    snapshot.map do |provider, buf|
      ok_obs    = buf.select { |o| o[:status] == :ok }
      err_obs   = buf.select { |o| o[:status] == :error }
      latencies = buf.filter_map { |o| o[:latency_ms] }
      {
        provider:           provider,
        total:              buf.length,
        ok:                 ok_obs.length,
        error:              err_obs.length,
        success_rate:       buf.empty? ? nil : (ok_obs.length.to_f / buf.length),
        last_ok_at:         ok_obs.last&.dig(:at),
        last_error_at:      err_obs.last&.dig(:at),
        last_error_reason:  err_obs.last&.dig(:reason),
        last_http_status:   buf.last&.dig(:http_status),
        avg_latency_ms:     latencies.empty? ? nil : (latencies.sum.to_f / latencies.length).round
      }
    end.sort_by { |row| row[:provider] }
  end

  def reset!
    MUTEX.synchronize { @observations.clear }
  end

  def disabled?
    return false if ENV['HEALTH_REGISTRY'] == '1'
    ENV['RACK_ENV'] == 'test'
  end
end
