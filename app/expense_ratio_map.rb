# ExpenseRatioMap — curated expense ratios for common ETFs and mutual
# funds, plus the user's actual top-by-value holdings.
#
# Source: each fund's most recent prospectus / fund-overview page. Numbers
# are gross expense ratios (not net) where they differ; rounded to 2dp of
# basis points (0.0001 = 1bp). Annual fee in $ = `holding_value × ER`.
#
# Coverage strategy:
#   - All popular ETFs that show up in everyday DIY portfolios.
#   - The user's top-by-value holdings (Fidelity Freedom, T. Rowe
#     Retirement, MFS Lifetime, Fidelity active funds, VIP variable-
#     insurance funds, factor ETFs).
#   - Anything not covered returns nil → the audit shows it as "unknown"
#     and excludes it from the totals (rather than guessing).
#
# Update: when adding a fund, copy the latest prospectus number, not a
# rough memory of it — small differences compound at $2M.
module ExpenseRatioMap
  # Symbol → expense ratio (decimal, e.g. 0.0075 = 0.75%).
  RATIOS = {
    # === Vanguard ETFs ===
    'VOO'   => 0.0003, 'VTI'   => 0.0003, 'VEA'   => 0.0006, 'VWO'   => 0.0008,
    'VXUS'  => 0.0008, 'BND'   => 0.0003, 'BIV'   => 0.0004, 'BSV'   => 0.0004,
    'VGIT'  => 0.0004, 'VGSH'  => 0.0004, 'VGLT'  => 0.0004, 'EDV'   => 0.0006,
    'VCIT'  => 0.0004, 'VCSH'  => 0.0004, 'VYM'   => 0.0006, 'VUG'   => 0.0004,
    'VTV'   => 0.0004, 'VB'    => 0.0005, 'VNQ'   => 0.0013, 'VNQI'  => 0.0012,
    'VEU'   => 0.0008, 'VFH'   => 0.0010, 'VGT'   => 0.0010, 'VOOG'  => 0.0010,

    # === iShares / BlackRock ETFs ===
    'IVV'   => 0.0003, 'IJH'   => 0.0005, 'IJR'   => 0.0006, 'AGG'   => 0.0003,
    'IEF'   => 0.0015, 'TLT'   => 0.0015, 'IEFA'  => 0.0007, 'IEMG'  => 0.0009,
    'EFA'   => 0.0035, 'EEM'   => 0.0070, 'IYR'   => 0.0040, 'IYF'   => 0.0040,
    'USMV'  => 0.0015, 'MTUM'  => 0.0015, 'QUAL'  => 0.0015, 'VLUE'  => 0.0015,
    'EMGF'  => 0.0025, 'LQD'   => 0.0014, 'HYG'   => 0.0049,

    # === SPDR / State Street ETFs ===
    'SPY'   => 0.0009, 'XLK'   => 0.0008, 'XLF'   => 0.0008, 'GLD'   => 0.0040,
    'GLDM'  => 0.0010, 'SLV'   => 0.0050, 'DBC'   => 0.0085,

    # === Schwab ETFs ===
    'SCHB'  => 0.0003, 'SCHA'  => 0.0004, 'SCHD'  => 0.0006, 'SCHG'  => 0.0004,
    'SCHH'  => 0.0007,

    # === Invesco / Other ETFs ===
    'QQQ'   => 0.0020, 'IAU'   => 0.0025, 'SGOL'  => 0.0017, 'MGK'   => 0.0007,
    'DGRO'  => 0.0008, 'HDV'   => 0.0008, 'FTEC'  => 0.0008, 'DFAE'  => 0.0035,

    # === Fidelity index ETFs / mutual funds ===
    'FQAL'  => 0.0029, 'FVAL'  => 0.0029, 'FELC'  => 0.0018, 'FSMD'  => 0.0029,
    'FPADX' => 0.0008, 'FZROX' => 0.0000, 'FZILX' => 0.0000, 'FXNAX' => 0.0003,
    'FSKAX' => 0.0015, 'FTIHX' => 0.0006,

    # === Fidelity active mutual funds (your holdings + common siblings) ===
    'FMAGX' => 0.0055, 'FBGRX' => 0.0046, 'FVDFX' => 0.0064, 'FLCSX' => 0.0081,
    'FCNTX' => 0.0039, 'FEMKX' => 0.0086, 'FSKLX' => 0.0035, 'FISZX' => 0.0040,

    # === Fidelity VIP variable-insurance funds ===
    'FXVLT' => 0.0012, 'FJBAC' => 0.0050, 'FPDFC' => 0.0058, 'FMNDC' => 0.0058,
    'FVJIC' => 0.0080,

    # === Target-date / glide-path (your holdings + popular siblings) ===
    'FFTHX' => 0.0075, 'FXIFX' => 0.0012, 'FFFEX' => 0.0075, 'FFFGX' => 0.0075,
    'TRRJX' => 0.0059,
    'LFEAX' => 0.0074,

    # === Bonds / fixed income mutual funds ===
    'FUMBX' => 0.0003, 'PIMIX' => 0.0049,

    # === More Fidelity index / sector funds ===
    'FSMDX' => 0.0025, 'FSPGX' => 0.0035, 'FIADX' => 0.0085, 'FRESX' => 0.0074,
    'FSAJX' => 0.0025,

    # === Institutional fund-class CUSIPs (Comcast 401(k) — what Fidelity
    # files them under in the broker CSV when no public ticker exists). ERs
    # come from the plan summary documents; institutional shares are
    # typically 1–10 bps cheaper than retail equivalents.
    '84679Q106' => 0.0002,  # SP 500 INDEX PL CL G (institutional S&P 500)
    '84679Q783' => 0.0007,  # SP TTL INTL IDX CL G (institutional intl index)
    '20030Q609' => 0.0005,  # Vanguard Target 2035 institutional
    '20030Q708' => 0.0005,  # Vanguard Target 2040 institutional

    # === Other ETFs the user holds ===
    'SDY'   => 0.0035, 'EFAV'  => 0.0020, 'EAGG'  => 0.0008
  }.freeze

  module_function

  # Returns the expense ratio (decimal) for `symbol`, or nil if unknown.
  def for_symbol(symbol)
    RATIOS[symbol.to_s.upcase]
  end

  # True if we have coverage for the symbol.
  def known?(symbol)
    RATIOS.key?(symbol.to_s.upcase)
  end

  # Total fund count we cover (for UI footer / coverage stats).
  def coverage_count
    RATIOS.length
  end
end
