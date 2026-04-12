## 1. Environment & Config

- [x] 1.1 Update `Dotenv.load` in `market_data_service.rb` to load both `.env` and `.credentials` so both `FINNHUB_API_KEY` and `ALPHA_VANTAGE_API_KEY` are available

## 2. Provider Implementations

- [x] 2.1 Add private method `fetch_from_alpha_vantage(symbol)` — extracts existing Alpha Vantage logic from `fetch_quote`
- [x] 2.2 Add private method `fetch_from_finnhub(symbol)` — calls `https://finnhub.io/api/v1/quote?symbol=<symbol>&token=<key>`, returns nil if key absent; normalizes `c`, `dp`, `v` to internal hash shape
- [x] 2.3 Add private method `fetch_from_yahoo(symbol)` — calls `https://query1.finance.yahoo.com/v8/finance/chart/<symbol>`, normalizes `regularMarketPrice`, `regularMarketChangePercent`, `regularMarketVolume`

## 3. Provider Chain

- [x] 3.1 Refactor `fetch_quote` to iterate the ordered provider chain `[alpha_vantage, finnhub, yahoo]`, returning the first valid result
- [x] 3.2 Emit targeted `warn` for each provider that is skipped or fails (suppress in test env)
- [x] 3.3 Final fallback to `MOCK_PRICES` when all three providers fail, with a combined warning

## 4. Tests

- [x] 4.1 Add test: Finnhub is skipped when `FINNHUB_API_KEY` is absent
- [x] 4.2 Add test: `fetch_from_yahoo` returns a normalized hash with the expected keys
- [x] 4.3 Run full test suite (`make test`) and confirm all tests pass
