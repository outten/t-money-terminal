## 1. Data Layer — Finnhub Analyst & Profile

- [x] 1.1 Add `fetch_analyst_recommendations(symbol)` to `MarketDataService` — calls Finnhub `/stock/recommendation`, returns most recent snapshot hash `{ strong_buy:, buy:, hold:, sell:, strong_sell: }`, caches 24h with key `"analyst:#{symbol}"`
- [x] 1.2 Add `fetch_company_profile(symbol)` to `MarketDataService` — calls Finnhub `/stock/profile2`, returns profile hash, caches 24h with key `"profile:#{symbol}"`; returns hardcoded description for known ETFs (SPY, EWJ, VGK) when Finnhub data is sparse
- [x] 1.3 Add `fetch_historical(symbol, period)` to `MarketDataService` — fetches from Yahoo Finance `v8/finance/chart` with `range` param; falls back to Finnhub `/stock/candle`; returns array of `{ date:, close: }` or nil; caches 24h with key `"candle:#{symbol}:#{period}"`

## 2. Recommendation Engine Update

- [x] 2.1 Rewrite `RecommendationService.signal_for(symbol)` — use `MarketDataService.fetch_analyst_recommendations` as primary; compute analyst consensus signal; fall back to price-change-% momentum when no analyst data
- [x] 2.2 Update `RecommendationService.signals` to include `:signal_type` field (`"Analyst Consensus"` or `"Momentum Signal"`) and analyst counts in each result hash

## 3. Routes

- [x] 3.1 Add `GET /analysis/:symbol` route in `app/main.rb` — validate symbol is in known list; fetch quote, analyst, profile, and pass to `analysis.erb`; return 404 for unknown symbols
- [x] 3.2 Change `GET /recommendations` to `redirect '/dashboard', 301` in `app/main.rb`

## 4. Views — Dashboard

- [x] 4.1 Update `views/dashboard.erb` — make all symbol names in the summary table clickable links to `/analysis/:symbol`
- [x] 4.2 Add "Market Signals" section below summary table in `views/dashboard.erb` — one card per symbol showing: signal badge, symbol link, price, change %, analyst counts summary (if available), "View Analysis →" link

## 5. Views — Analysis Page

- [x] 5.1 Create `views/analysis.erb` — page structure with sections: header (symbol + signal badge), Analyst Consensus, Company Profile, Key Financials, Historical Chart, External Links
- [x] 5.2 Analyst Consensus section — display Strong Buy / Buy / Hold / Sell / Strong Sell counts as a bar or count display; show signal type label; cite "Source: Finnhub"
- [x] 5.3 Company Profile section — name, description, exchange, industry, market cap, PE ratio, IPO date, 52-week high/low; cite source; show hardcoded ETF description where applicable
- [x] 5.4 External links — Google Finance and Yahoo Finance buttons, both `target="_blank" rel="noopener noreferrer"`
- [x] 5.5 Historical chart — Chart.js line chart with period toggle buttons (1D, 1M, 3M, YTD, 1Y, 5Y); cite "Source: Yahoo Finance / Finnhub"; show no-data notice when data unavailable

## 6. Views — Layout & Navigation

- [x] 6.1 Remove "Recommendations" link from `views/layout.erb` nav bar

## 7. JavaScript

- [x] 7.1 Add `renderHistoricalChart(canvasId, labels, data)` to `public/app.js`
- [x] 7.2 Add period toggle logic in `public/app.js` — clicking a period button fetches `/api/candle/:symbol/:period` and re-renders the chart
- [x] 7.3 Add `GET /api/candle/:symbol/:period` JSON endpoint in `app/main.rb` for async period switching

## 8. Tests

- [x] 8.1 Update `spec/app_spec.rb` — add test for `GET /analysis/SPY` (200), `GET /analysis/INVALID` (404), `GET /recommendations` (301 redirect)
- [x] 8.2 Update `spec/services_spec.rb` — add tests for `fetch_analyst_recommendations` (nil when key absent), `fetch_company_profile` (returns hash), `signal_for` signal type label
- [x] 8.3 Run full test suite (`make test`) and confirm all tests pass
