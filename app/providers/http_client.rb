require 'net/http'
require 'uri'
require 'json'
require_relative '../health_registry'

module Providers
  # Thin Net::HTTP wrapper used by provider modules. Centralizes timeout
  # defaults, JSON parsing, and rate-limit (429) detection. When called with
  # `provider:` set, every call is reported to HealthRegistry so the admin
  # health panel reflects real upstream availability.
  module HttpClient
    DEFAULT_HEADERS = {
      'Accept'     => 'application/json',
      'User-Agent' => 'T-Money-Terminal/1.0 (+https://github.com/)'
    }.freeze

    module_function

    # Returns [http_status_int, parsed_body_or_nil, raw_body_string]
    # parsed_body is nil when body is not JSON.
    def get_json(url, headers: {}, timeout: 10, provider: nil)
      perform(:json, url, headers: headers, timeout: timeout, provider: provider)
    end

    # Plain-text GET (for CSV endpoints like Stooq).
    def get_text(url, headers: {}, timeout: 10, provider: nil)
      perform(:text, url, headers: headers, timeout: timeout, provider: provider)
    end

    # --- internal -----------------------------------------------------------

    def perform(mode, url, headers:, timeout:, provider:)
      uri = url.is_a?(URI) ? url : URI(url)
      base_headers = mode == :text ? DEFAULT_HEADERS.merge('Accept' => 'text/csv, text/plain, */*') : DEFAULT_HEADERS

      req = Net::HTTP::Get.new(uri)
      base_headers.merge(headers).each { |k, v| req[k] = v }

      started = Time.now
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                            read_timeout: timeout, open_timeout: 5) do |http|
        http.request(req)
      end
      latency = ((Time.now - started) * 1000).round
      code    = res.code.to_i

      if mode == :json
        body   = res.body.to_s
        parsed = begin
                   body.empty? ? nil : JSON.parse(body)
                 rescue JSON::ParserError
                   nil
                 end
        report(provider, code, latency)
        [code, parsed, body]
      else
        body = res.body.to_s
        report(provider, code, latency)
        [code, body]
      end
    rescue StandardError => e
      if provider
        HealthRegistry.record(
          provider:    provider,
          status:      :error,
          reason:      "#{e.class}: #{e.message}".slice(0, 200),
          http_status: nil,
          latency_ms:  nil
        )
      end
      raise
    end

    def report(provider, code, latency)
      return unless provider
      status = (200..299).cover?(code) ? :ok : :error
      reason = case code
               when 200..299 then nil
               when 429 then 'rate_limited'
               when 401, 403 then 'unauthorized'
               when 404 then 'not_found'
               when 500..599 then 'upstream_error'
               else "http_#{code}"
               end
      HealthRegistry.record(
        provider:    provider,
        status:      status,
        reason:      reason,
        http_status: code,
        latency_ms:  latency
      )
    end
  end
end
