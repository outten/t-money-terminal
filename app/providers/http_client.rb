require 'net/http'
require 'uri'
require 'json'

module Providers
  # Thin Net::HTTP wrapper used by provider modules. Centralizes timeout
  # defaults, JSON parsing, and rate-limit (429) detection.
  module HttpClient
    DEFAULT_HEADERS = {
      'Accept'     => 'application/json',
      'User-Agent' => 'T-Money-Terminal/1.0 (+https://github.com/)'
    }.freeze

    module_function

    # Returns [http_status_int, parsed_body_or_nil, raw_body_string]
    # parsed_body is nil when body is not JSON.
    def get_json(url, headers: {}, timeout: 10)
      uri = url.is_a?(URI) ? url : URI(url)
      req = Net::HTTP::Get.new(uri)
      DEFAULT_HEADERS.merge(headers).each { |k, v| req[k] = v }

      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                            read_timeout: timeout, open_timeout: 5) do |http|
        http.request(req)
      end

      body = res.body.to_s
      parsed = begin
                 body.empty? ? nil : JSON.parse(body)
               rescue JSON::ParserError
                 nil
               end

      [res.code.to_i, parsed, body]
    end

    # Plain-text GET (for CSV endpoints like Stooq).
    def get_text(url, headers: {}, timeout: 10)
      uri = url.is_a?(URI) ? url : URI(url)
      req = Net::HTTP::Get.new(uri)
      DEFAULT_HEADERS.merge({ 'Accept' => 'text/csv, text/plain, */*' }).merge(headers)
                     .each { |k, v| req[k] = v }

      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                            read_timeout: timeout, open_timeout: 5) do |http|
        http.request(req)
      end

      [res.code.to_i, res.body.to_s]
    end
  end
end
