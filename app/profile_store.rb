require 'json'
require 'fileutils'

# ProfileStore — single-user investment-profile config persisted at
# `data/profile.json`. Drives the tax-harvest analysis (and any future
# planning surface) with the user's age, retirement timeline, risk
# tolerance, and marginal tax rates.
#
# Schema:
#   {
#     current_age:           Integer,         # e.g. 56
#     retirement_age:        Integer,         # e.g. 63
#     risk_tolerance:        'aggressive' | 'moderate' | 'conservative',
#     federal_ltcg_rate:     Float,           # e.g. 0.15 (15%)
#     federal_ordinary_rate: Float,           # e.g. 0.22 (22%)
#     state_tax_rate:        Float | nil,     # e.g. 0.05; nil = ignore
#     niit_applies:          Boolean,         # 3.8% Net Investment Income Tax (high earners)
#     updated_at:            ISO timestamp
#   }
#
# All fields have sensible defaults so the feature works before the user
# customises anything. `risk_tolerance` defaults to 'moderate'; tax rates
# default to the most-common-bracket numbers (LTCG 15%, ordinary 22%).
module ProfileStore
  DEFAULT_PATH = File.expand_path('../../data/profile.json', __FILE__)
  MUTEX        = Mutex.new

  RISK_TOLERANCES = %w[aggressive moderate conservative].freeze

  DEFAULTS = {
    current_age:           nil,
    retirement_age:        65,
    risk_tolerance:        'moderate',
    federal_ltcg_rate:     0.15,
    federal_ordinary_rate: 0.22,
    state_tax_rate:        nil,
    niit_applies:          false
  }.freeze

  module_function

  def path
    ENV['PROFILE_PATH'] || DEFAULT_PATH
  end

  # Returns the persisted profile merged over DEFAULTS so callers always
  # have every field present.
  def read
    persisted = read_unlocked
    DEFAULTS.merge(persisted)
  end

  # True iff current_age is set — the tax-harvest analysis won't compute
  # accurately until the user has set their age. The page renders a
  # config-needed empty state otherwise.
  def configured?
    !read[:current_age].nil?
  end

  # Years until retirement. Useful for retirement-window-aware
  # recommendations (closer = more conservative). Returns nil when
  # current_age isn't set.
  def years_to_retirement
    p = read
    return nil unless p[:current_age]
    (p[:retirement_age] - p[:current_age]).to_i
  end

  # Update one or more fields. Validates types + ranges; raises
  # ArgumentError on bad input. Returns the updated profile.
  def update(updates)
    raise ArgumentError, 'updates must be a Hash' unless updates.is_a?(Hash)
    sanitized = sanitize(updates)

    MUTEX.synchronize do
      current = read_unlocked
      merged  = current.merge(sanitized)
      merged[:updated_at] = Time.now.utc.iso8601
      write_unlocked(merged)
      DEFAULTS.merge(merged)
    end
  end

  # --- internals -----------------------------------------------------------

  def sanitize(input)
    out = {}
    input.each do |k, v|
      key = k.to_sym
      case key
      when :current_age, :retirement_age
        next if v.to_s.strip.empty? # leave existing value alone
        n = Integer(v) rescue nil
        raise ArgumentError, "#{key} must be an integer 0..120" if n.nil? || !n.between?(0, 120)
        out[key] = n
      when :risk_tolerance
        s = v.to_s.strip.downcase
        next if s.empty?
        raise ArgumentError, "risk_tolerance must be one of #{RISK_TOLERANCES.inspect}" unless RISK_TOLERANCES.include?(s)
        out[key] = s
      when :federal_ltcg_rate, :federal_ordinary_rate, :state_tax_rate
        next if v.nil? || v.to_s.strip.empty?
        f = Float(v) rescue nil
        raise ArgumentError, "#{key} must be 0..0.5 (decimal, not percent)" if f.nil? || !f.between?(0, 0.5)
        out[key] = f
      when :niit_applies
        out[key] = !!(v == true || v == 'true' || v == '1' || v == 1)
      end
    end

    if out[:current_age] && out[:retirement_age] && out[:retirement_age] < out[:current_age]
      raise ArgumentError, 'retirement_age cannot be earlier than current_age'
    end
    out
  end

  def read_unlocked
    return {} unless File.exist?(path)
    raw = File.read(path)
    return {} if raw.strip.empty?
    parsed = JSON.parse(raw)
    return {} unless parsed.is_a?(Hash)
    parsed.transform_keys(&:to_sym)
  rescue JSON::ParserError
    {}
  end

  def write_unlocked(profile)
    FileUtils.mkdir_p(File.dirname(path))
    tmp = "#{path}.tmp"
    File.write(tmp, JSON.pretty_generate(profile))
    File.rename(tmp, path)
  end
end
