# Developer Guide: T Money Terminal

## Project Structure
```
app/
  main.rb                  # Sinatra routes
  market_data_service.rb   # Alpha Vantage + 24h cache + mock fallback
  recommendation_service.rb # Buy/Sell/Hold signal logic
views/
  layout.erb               # Shared layout, nav, footer
  dashboard.erb            # Global summary
  us_markets.erb           # US page
  japan_markets.erb        # Japan proxy (EWJ)
  europe_markets.erb       # Europe proxy (VGK)
  recommendations.erb      # Signals table
public/
  style.css                # Apple-inspired design, dark mode
  app.js                   # Chart helpers, theme toggle
scripts/
  refresh_cache.rb         # Manually bust the 24h data cache
spec/
  app_spec.rb              # Route smoke tests
  services_spec.rb         # Unit tests for services
Makefile                   # install / run / test / refresh-cache
```

## Setup
```bash
make install   # bundle install
make run       # start on http://localhost:4567
make test      # run RSpec suite
make refresh-cache  # bust data cache on next request
```

## Caching
- Market data is cached in **hierarchical disk files** at `data/cache/` for **1 hour** (`MarketDataService::CACHE_TTL = 3600`)
- Cache structure: `data/cache/{quotes,historical,analyst,profiles}/SYMBOL[_PERIOD].json`
- Run `make refresh-cache` or click **REFRESH** button in UI to clear and refetch
- Fallback to `MOCK_PRICES` when cache is empty and API key is absent
- Legacy monolithic cache at `.cache/market_cache.json` auto-migrates on first load

## Signals
- `RecommendationService` issues BUY/SELL/HOLD based on price change percent
- Extend with SMA/RSI using Alpha Vantage Technical Indicator endpoints

## API Docs
- Alpha Vantage: https://www.alphavantage.co/documentation/
- Japan proxy: EWJ (iShares MSCI Japan ETF)
- Europe proxy: VGK (Vanguard FTSE Europe ETF)

## Contribution
- Fork, branch, and submit PRs
- Write tests for new features
- Keep documentation up to date
