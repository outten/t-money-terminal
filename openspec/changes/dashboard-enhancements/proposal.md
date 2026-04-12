## Why

The dashboard currently shows a fixed small set of symbols with limited metadata — no symbol type classification, no clickable region links, and a simplistic signal indicator. Users need richer at-a-glance data to make informed decisions quickly, and the analysis page lacks the company homepage link that would help users do deeper research.

## What Changes

- Expand dashboard symbol list to show top 10, 25, or 50 symbols (constrained by API rate limits and free-tier quotas)
- Add a "Type" column to the dashboard symbols table identifying each symbol as Equity, ETF, Mutual Fund, or Option
- Make the Region column values clickable links to region-specific pages
- Update region-specific pages to show the same enriched table/data as the dashboard, filtered to that region's symbols
- Compute the dashboard Signal column using a weighted average of analyst buy/hold/sell recommendation counts rather than a simple categorical signal
- Add a homepage link on the analysis page when the company/fund website URL is available from the data provider

## Capabilities

### New Capabilities
- `region-filtered-dashboard`: Region-specific pages that mirror the main dashboard but scoped to one region's symbols

### Modified Capabilities
- `multi-page-navigation`: Region values become links; new region-filtered pages are added to the nav structure
- `recommendation-engine`: Signal computation changes from categorical to weighted-average buy/hold/sell score
- `symbol-analysis-page`: Add optional homepage URL link sourced from company profile data

## Impact

- `app/main.rb`: New `/region/:name` route; update dashboard route to pass more symbols
- `app/market_data_service.rb`: Profile data already fetched (includes `weburl`); symbol-type classification needed
- `app/recommendation_service.rb`: Weighted-average signal score replacing simple majority-vote signal
- `views/dashboard.erb`: Add Type column, linkify Region column
- `views/analysis.erb`: Add homepage link in header/profile section
- New view: `views/region.erb` (mirrors dashboard, filtered)
- Symbol list expansion subject to Alpha Vantage 25 req/day and Finnhub free-tier rate limits
