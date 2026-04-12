## 1. Dev Server (rerun)

- [x] 1.1 Add `dev` target to Makefile: `bundle exec rerun 'ruby app/main.rb'`
- [x] 1.2 Verify `bundle exec rerun --version` works (gem already in Gemfile)

## 2. Live Market Data

- [x] 2.1 In `MarketDataService#fetch_quote`, add `warn` to stderr when `API_KEY` is absent (skip in test env)
- [x] 2.2 In `MarketDataService#fetch_quote`, add `warn` to stderr on HTTP/parse failure before falling back to mock
- [ ] 2.3 Smoke-test live data path manually: run `make dev`, load `/dashboard`, confirm real prices appear in the browser

## 3. Tests

- [x] 3.1 Update `spec/services_spec.rb` to assert a warning is emitted when `ALPHA_VANTAGE_API_KEY` is absent
- [x] 3.2 Run full test suite (`make test`) and confirm all tests pass
