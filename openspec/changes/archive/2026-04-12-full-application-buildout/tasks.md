## 1. Shared Layout & Navigation

- [x] 1.1 Create views/layout.erb with header, nav bar (Dashboard, US, Japan, Europe, Recommendations), and footer
- [x] 1.2 Add light/dark mode toggle to layout with localStorage persistence
- [x] 1.3 Highlight active navigation item based on current route
- [x] 1.4 Update app/main.rb to use layout.erb for all views

## 2. Market Pages

- [x] 2.1 Create views/dashboard.erb (rename current index.erb to dashboard)
- [x] 2.2 Create views/us_markets.erb with US symbols (SPY, AAPL, MSFT)
- [x] 2.3 Create views/japan_markets.erb with Japan proxy (EWJ ETF)
- [x] 2.4 Create views/europe_markets.erb with Europe proxy (VGK ETF)
- [x] 2.5 Add Sinatra routes for /dashboard, /us, /japan, /europe

## 3. Real-Time Market Data Integration

- [x] 3.1 Expand MarketDataService to fetch quotes and daily time series for multiple symbols
- [x] 3.2 Add in-memory caching (24-hour TTL) for Alpha Vantage responses
- [x] 3.2b Add scripts/refresh_cache.rb to bust cache on demand
- [x] 3.3 Add fallback to mock data with "Data may be delayed" notice when API unavailable
- [x] 3.4 Create Sinatra JSON endpoints: /api/market/us, /api/market/japan, /api/market/europe

## 4. Recommendation Engine

- [x] 4.1 Create app/recommendation_service.rb with buy/sell/hold logic (SMA crossover + RSI)
- [x] 4.2 Create views/recommendations.erb displaying signals per symbol with rationale
- [x] 4.3 Add Sinatra route /recommendations
- [x] 4.4 Add prominent disclaimer on recommendations page

## 5. Charts & Visualizations

- [x] 5.1 Add line chart for price history on each market page
- [x] 5.2 Add bar chart for volume on each market page
- [x] 5.3 Add summary table (symbol, price, change, signal) on dashboard and recommendations

## 6. Instructions Guide

- [x] 6.1 Create Instructions.md covering API key registration, .credentials setup, and running the app
- [x] 6.2 Document how to interpret buy/sell/hold recommendations and chart data

## 7. Testing

- [x] 7.1 Add smoke tests for all routes (/dashboard, /us, /japan, /europe, /recommendations)
- [x] 7.2 Add unit tests for RecommendationService with mock data
- [x] 7.3 Add tests for MarketDataService caching and fallback logic

## 8. Documentation & Makefile

- [x] 8.1 Update README.md with full feature list and navigation guide
- [x] 8.2 Update DEVELOPER.md with new file structure and services
- [x] 8.3 Add make install target, make refresh-cache, and any new Makefile commands
