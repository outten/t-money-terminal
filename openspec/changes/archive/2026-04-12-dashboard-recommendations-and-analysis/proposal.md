## Why

The current Recommendations page is isolated and shows only simple BUY/SELL/HOLD signals derived from price change %, with no analyst consensus data, no company context, and no deep-dive capability. Moving recommendations onto the Dashboard and building per-symbol Analysis pages — backed by Finnhub's real analyst data — transforms the terminal from a price display into an actionable research tool.

## What Changes

- Finnhub becomes the data source for analyst recommendations (consensus buy/hold/sell counts from firms) and company/fund profile information
- The standalone Recommendations page is **removed**; recommendations with stock details are embedded directly in the Dashboard
- Every symbol on the Dashboard becomes a clickable link to a new `/analysis/:symbol` route
- New **Analysis page** per symbol shows:
  - BUY/SELL/HOLD signal (from Finnhub analyst consensus, not just price change)
  - Analyst breakdown: count of Strong Buy / Buy / Hold / Sell / Strong Sell recommendations from Wall Street firms (Finnhub `/stock/recommendation`)
  - Company/ETF/fund profile: name, description, exchange, industry, market cap, PE ratio, 52-week high/low (Finnhub `/stock/profile2` + `/quote`)
  - Links to Google Finance and Yahoo Finance (open in new tab)
  - Historical price charts: 1D, 1M, 3M, YTD, 1Y, 5Y using Chart.js (data from Finnhub `/stock/candle` or Yahoo Finance chart endpoint as fallback)
  - Source citations for each data section
- **BREAKING**: `GET /recommendations` route removed; replaced by `GET /analysis/:symbol`
- `RecommendationService` updated to use Finnhub analyst consensus as primary signal source

## Capabilities

### New Capabilities
- `symbol-analysis-page`: Per-symbol deep-dive page with analyst consensus, company profile, financials, historical charts, and source citations
- `finnhub-analyst-data`: Fetches and caches Finnhub analyst recommendation counts and company/ETF profile data

### Modified Capabilities
- `recommendation-engine`: Signal generation now uses Finnhub analyst consensus (strong buy > buy > hold etc.) as primary source instead of price change %
- `multi-page-navigation`: Recommendations nav item removed; symbol links on Dashboard route to `/analysis/:symbol`

## Impact

- `app/main.rb` — add `GET /analysis/:symbol`, remove or redirect `GET /recommendations`
- `app/market_data_service.rb` — add Finnhub analyst and profile fetch methods
- `app/recommendation_service.rb` — rewrite signal logic to use analyst consensus
- `views/dashboard.erb` — embed recommendations with full stock data; make symbols clickable
- `views/analysis.erb` — new view (the analysis page)
- `views/recommendations.erb` — removed
- `views/layout.erb` — remove Recommendations nav item
- `public/app.js` — add historical chart rendering (multi-period toggle)
- `spec/app_spec.rb` / `spec/services_spec.rb` — update tests for new routes and services
- Finnhub API key already configured in `.env`; 24h cache applies to all new endpoints
