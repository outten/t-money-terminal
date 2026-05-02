# AccountClassifier — normalize a broker account name (Fidelity-style strings
# like "Individual - TOD" or "COMCAST CORPORATION RETIREMENT-INVESTMENT PLAN")
# into one of these tax kinds:
#
#   taxable           — brokerage / trust accounts, trading from after-tax dollars
#   roth              — Roth IRA / Roth 401(k); contributions taxed, growth + withdrawals tax-free
#   traditional_ira   — Traditional IRA; deductible contributions, withdrawals taxed
#   tax_deferred_401k — 401(k), 403(b), 457, employer plans; tax-deferred until withdrawal
#   deferred_annuity  — non-qualified deferred annuity; complicated tax treatment
#   hsa               — Health Savings Account; triple-tax-advantaged
#   other             — couldn't classify confidently
#
# This drives the /portfolio account-type allocation section and is the
# foundation for the planned tax-efficient location, Roth conversion, and
# RMD features (TODOs U / V / W).
module AccountClassifier
  KINDS = %w[taxable roth traditional_ira tax_deferred_401k deferred_annuity hsa other].freeze

  # Order matters — first matching pattern wins. Roth IRA must come before
  # the broader "IRA" rule, etc.
  RULES = [
    [/\bROTH\b/i,                                                       'roth'],
    [/\bHSA\b|HEALTH\s+SAVINGS/i,                                       'hsa'],
    [/\bTRADITIONAL\s+IRA\b|\bTRAD\s+IRA\b/i,                           'traditional_ira'],
    [/(401\s*[(\-]?\s*K|403\s*[(\-]?\s*B|457\s*[(\-]?\s*B?|\bTSP\b)/i,  'tax_deferred_401k'],
    [/RETIREMENT[\s-]+(INVESTMENT\s+)?PLAN|EMPLOYEE\s+PLAN/i,           'tax_deferred_401k'],
    [/DEFERRED\s+ANNUITY|VARIABLE\s+ANNUITY|\bANNUITY\b/i,              'deferred_annuity'],
    [/\bIRA\b/i,                                                        'traditional_ira'],
    [/INDIVIDUAL[\s-]/i,                                                'taxable'],
    [/\bJOINT\b|\bTOD\b|\bTRUST\b|TAXABLE/i,                            'taxable'],
    [/CASH\s+MANAGEMENT|CHECKING|SAVINGS\s+ACCOUNT/i,                   'taxable']
  ].freeze

  module_function

  # Normalize a raw account name to a kind. Returns 'other' when nothing
  # matches — surfaced honestly in the UI.
  def classify(account_name)
    name = account_name.to_s
    return 'other' if name.strip.empty?
    RULES.each do |regex, kind|
      return kind if name.match?(regex)
    end
    'other'
  end

  # Human-readable label for the UI.
  def kind_label(kind)
    {
      'taxable'           => 'Taxable',
      'roth'              => 'Roth',
      'traditional_ira'   => 'Traditional IRA',
      'tax_deferred_401k' => 'Tax-deferred (401k / 403b / 457)',
      'deferred_annuity'  => 'Deferred annuity',
      'hsa'               => 'HSA',
      'other'             => 'Other / unclassified'
    }[kind] || kind
  end

  # Color for inline progress bars on /portfolio. Same palette as
  # AssetClassMapper but tax-kind-keyed.
  def kind_color(kind)
    {
      'taxable'           => '#0071e3',
      'roth'              => '#34c759',
      'traditional_ira'   => '#ff9500',
      'tax_deferred_401k' => '#5ac8fa',
      'deferred_annuity'  => '#a47148',
      'hsa'               => '#af52de',
      'other'             => '#999'
    }[kind] || '#999'
  end
end
