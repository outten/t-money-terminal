require 'date'
require_relative 'trades_store'

# WashSale — flag IRS wash-sale risk on a SELL with a realized loss.
#
# IRS rule (US): a wash sale occurs when you sell or trade a security at
# a loss and, within 30 days BEFORE or AFTER the sale, you (or your
# spouse / IRA) buy a "substantially identical" security. The loss is
# disallowed for current-year tax purposes; it gets added to the cost
# basis of the replacement shares.
#
# This module does *risk flagging*, not tax preparation. We scan
# TradesStore for same-symbol BUY trades within ±30 days of a SELL with
# realized loss and surface a warning. We can't enforce the disallowance
# in PortfolioStore — that's a tax-prep concern.
#
# Limitations (intentional, surfaced in the UI):
# - Only same-symbol matching. "Substantially identical" can include
#   options, mutual funds tracking the same index, etc. — out of scope.
# - We can't see other accounts (spouse, IRA elsewhere, other brokers).
# - We use TradesStore as the BUY source. Imports also write BUY trade
#   records, so Fidelity-imported acquisitions count.
module WashSale
  WINDOW_DAYS = 30

  module_function

  # Inspect a sell breakdown (from PortfolioStore.close_shares_fifo) and
  # return any wash-sale risk flags. Only sells with realized loss can
  # trigger a flag.
  #
  # Returns:
  #   [{ matching_buy: <trade hash>, days_apart:, direction: 'before'|'after',
  #      shares_at_risk:, allowed_resume_date: ISO date }, ...]
  # Empty array means no flags.
  def check(breakdown)
    return [] unless breakdown.is_a?(Hash)
    return [] unless breakdown[:realized_pl].to_f < 0

    sym      = breakdown[:symbol].to_s.upcase
    sold_at  = parse_date(breakdown[:sold_at]) || Date.today
    window_a = sold_at - WINDOW_DAYS
    window_b = sold_at + WINDOW_DAYS

    matches = TradesStore.read.select do |t|
      next false unless t[:symbol] == sym && t[:side] == 'buy'
      d = parse_date(t[:date])
      next false unless d
      d >= window_a && d <= window_b && d != sold_at
    end

    matches.map do |trade|
      d = parse_date(trade[:date])
      direction = d < sold_at ? 'before' : 'after'
      {
        matching_buy:        trade,
        days_apart:          (sold_at - d).to_i.abs,
        direction:           direction,
        shares_at_risk:      [breakdown[:shares_closed].to_f, trade[:shares].to_f].min,
        allowed_resume_date: (sold_at + WINDOW_DAYS + 1).iso8601
      }
    end
  end

  # Convenience: a single human-readable summary string per flag, for
  # rendering on /trades and the sell preview.
  def summarize_flag(flag)
    bp = flag[:matching_buy]
    direction = flag[:direction] == 'before' ? 'before' : 'after'
    "Possible wash sale: bought #{bp[:shares]} sh of #{bp[:symbol]} on #{bp[:date]} " \
      "(#{flag[:days_apart]} days #{direction} this sell). Wait until " \
      "#{flag[:allowed_resume_date]} to repurchase to avoid the wash-sale rule."
  end

  def parse_date(raw)
    return raw if raw.is_a?(Date)
    Date.parse(raw.to_s)
  rescue StandardError
    nil
  end
end
