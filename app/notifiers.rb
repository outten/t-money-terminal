require 'json'
require 'net/http'
require 'uri'

# Notifiers — pluggable outbound notification dispatch for triggered alerts.
#
# Configured purely via environment variables, so adding a notifier is just
# setting an env var in `.credentials`:
#
#   ALERT_WEBHOOK_URL=https://hooks.slack.com/services/...   # POST JSON
#   ALERT_NTFY_TOPIC=tmoney-alerts                           # ntfy.sh topic
#   ALERT_NTFY_SERVER=https://ntfy.sh                        # default ntfy.sh
#   ALERT_EMAIL_TO=alerts@example.com                        # SMTP (requires *_SMTP_* below)
#   ALERT_SMTP_HOST=smtp.gmail.com
#   ALERT_SMTP_PORT=587
#   ALERT_SMTP_USER=user@example.com
#   ALERT_SMTP_PASS=app-password
#   ALERT_SMTP_FROM=alerts@example.com
#
# `Notifiers.dispatch(alert)` fires every configured channel and returns an
# array of { channel:, ok:, error: } so the caller can log the result. Each
# channel is best-effort — one failing notifier should never block another.
module Notifiers
  module_function

  # Returns array of result hashes, one per configured channel.
  def dispatch(alert)
    results = []

    if (url = ENV['ALERT_WEBHOOK_URL']) && !url.empty?
      results << safe_send(:webhook) { send_webhook(url, alert) }
    end

    if (topic = ENV['ALERT_NTFY_TOPIC']) && !topic.empty?
      server = ENV['ALERT_NTFY_SERVER'].to_s.empty? ? 'https://ntfy.sh' : ENV['ALERT_NTFY_SERVER']
      results << safe_send(:ntfy) { send_ntfy(server, topic, alert) }
    end

    if (to = ENV['ALERT_EMAIL_TO']) && !to.empty?
      results << safe_send(:email) { send_email(to, alert) }
    end

    results
  end

  # Returns the list of configured channel names — used by `make check-alerts`
  # output to remind the user when no channels are wired up.
  def configured_channels
    [].tap do |list|
      list << :webhook if ENV['ALERT_WEBHOOK_URL']  && !ENV['ALERT_WEBHOOK_URL'].empty?
      list << :ntfy    if ENV['ALERT_NTFY_TOPIC']   && !ENV['ALERT_NTFY_TOPIC'].empty?
      list << :email   if ENV['ALERT_EMAIL_TO']     && !ENV['ALERT_EMAIL_TO'].empty?
    end
  end

  # --- internals -----------------------------------------------------------

  def safe_send(channel)
    yield
    { channel: channel, ok: true, error: nil }
  rescue StandardError => e
    { channel: channel, ok: false, error: "#{e.class}: #{e.message}" }
  end

  def send_webhook(url, alert)
    uri  = URI(url)
    body = build_payload(alert).to_json
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.read_timeout = 10
    req = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json')
    req.body = body
    res = http.request(req)
    raise "HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
  end

  def send_ntfy(server, topic, alert)
    uri = URI("#{server.chomp('/')}/#{topic}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.read_timeout = 10

    title = "Alert: #{alert[:symbol]} #{alert[:condition]} #{alert[:threshold]}"
    body  = format_text(alert)

    req = Net::HTTP::Post.new(uri.request_uri)
    req['Title']    = title
    req['Priority'] = 'default'
    req['Tags']     = alert[:condition] == 'above' ? 'arrow_up' : 'arrow_down'
    req.body = body
    res = http.request(req)
    raise "HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
  end

  # SMTP delivery via Net::SMTP (ships with Ruby standard lib in 3.0+;
  # net-smtp gem in 3.1+). Required env: ALERT_SMTP_HOST/USER/PASS/FROM.
  # Optional: ALERT_SMTP_PORT (default 587), ALERT_SMTP_TLS (default 'starttls').
  def send_email(to, alert)
    require 'net/smtp'
    host = ENV['ALERT_SMTP_HOST']
    user = ENV['ALERT_SMTP_USER']
    pass = ENV['ALERT_SMTP_PASS']
    from = ENV['ALERT_SMTP_FROM'] || user
    port = (ENV['ALERT_SMTP_PORT'] || 587).to_i
    raise 'ALERT_SMTP_HOST / USER / PASS / FROM required' if [host, user, pass, from].any? { |x| x.to_s.empty? }

    subject = "T Money Terminal alert: #{alert[:symbol]} #{alert[:condition]} #{alert[:threshold]}"
    body    = format_text(alert)
    message = <<~MSG
      From: #{from}
      To: #{to}
      Subject: #{subject}
      MIME-Version: 1.0
      Content-Type: text/plain; charset=utf-8

      #{body}
    MSG

    smtp = Net::SMTP.new(host, port)
    smtp.enable_starttls if port == 587
    smtp.start(host, user, pass, :login) do |s|
      s.send_message message, from, [to]
    end
  end

  def build_payload(alert)
    {
      symbol:       alert[:symbol],
      condition:    alert[:condition],
      threshold:    alert[:threshold],
      last_price:   alert[:last_price],
      triggered_at: alert[:triggered_at],
      message:      format_text(alert)
    }
  end

  def format_text(alert)
    "#{alert[:symbol]} crossed #{alert[:condition]} #{alert[:threshold]} — last price $#{alert[:last_price]}."
  end
end
