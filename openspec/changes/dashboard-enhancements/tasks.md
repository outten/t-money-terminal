## 1. Expand Symbol List

- [x] 1.1 Audit current symbol list and curate a target list of 15–20 symbols across US/Japan/Europe regions
- [x] 1.2 Update `SYMBOLS` (or equivalent constant) in `app/market_data_service.rb` with the expanded list
- [x] 1.3 Update `scripts/refresh_cache.rb` symbol list to match
- [x] 1.4 Run `make refresh-cache` and verify quotes fetch without hitting AV daily limit

## 2. Symbol Type Column

- [x] 2.1 Add `SYMBOL_TYPES` hash in `MarketDataService` mapping known ETF/fund symbols to their type label
- [x] 2.2 Add `symbol_type(symbol)` class method that returns the hardcoded type, falling back to Finnhub profile `type` field mapped to a human label (e.g., "EQS" → "Equity", "ETF" → "ETF")
- [x] 2.3 Pass `symbol_types` map to the dashboard view in `app/main.rb`
- [x] 2.4 Add a "Type" column to the symbol table in `views/dashboard.erb`
- [x] 2.5 Style the type badge in `public/style.css` (distinct from signal badge)

## 3. Weighted-Average Signal

- [x] 3.1 Replace the existing threshold inequality logic in `RecommendationService` with the weighted-average score formula: `(strongBuy×2 + buy×1 + hold×0 + sell×−1 + strongSell×−2) / total_votes`
- [x] 3.2 Define `BUY_THRESHOLD = 0.5` and `SELL_THRESHOLD = -0.5` constants in `RecommendationService`
- [x] 3.3 Include the numeric `score` value in the `signal_detail` return hash
- [x] 3.4 Update `spec/services_spec.rb` tests to cover the new thresholds and score value

## 4. Region Links and Region Pages

- [x] 4.1 Extract the dashboard symbol table markup into `views/_symbol_table.erb` partial
- [x] 4.2 Update `views/dashboard.erb` to render the partial via `<%= erb :_symbol_table, locals: { ... } %>`
- [x] 4.3 Make each region value in the table a link to `/region/:name` (e.g., `<a href="/region/us">US</a>`)
- [x] 4.4 Add `REGIONS` map in `app/main.rb` (or `MarketDataService`) mapping region names to symbol lists
- [x] 4.5 Add `GET /region/:name` route in `app/main.rb` — fetch quotes for region symbols, render `views/region.erb`; return 404 for unknown region names
- [x] 4.6 Create `views/region.erb` that renders the `_symbol_table` partial with the filtered symbol list and a region-specific heading
- [x] 4.7 Update nav active-state highlighting logic to cover region pages

## 5. Analysis Page Homepage Link

- [x] 5.1 Confirm `@profile` in the analysis route already includes `weburl` from Finnhub (inspect cached profile data)
- [x] 5.2 In `views/analysis.erb`, add a "Website" link inside the profile section that renders only when `@profile[:weburl]` is present and non-blank
- [x] 5.3 Ensure the link has `target="_blank" rel="noopener noreferrer"`

## 6. Tests and Cleanup

- [x] 6.1 Add RSpec test for `symbol_type` method covering hardcoded ETF, Finnhub-profile-backed equity, and unknown fallback
- [x] 6.2 Add RSpec test for `/region/us` returning 200 and `/region/unknown` returning 404
- [x] 6.3 Run full test suite (`bundle exec rspec`) and confirm all tests pass
- [x] 6.4 Run `make refresh-symbol SYMBOL=AAPL` and verify analysis page shows homepage link for AAPL
