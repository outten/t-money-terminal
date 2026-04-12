## Why

The current application is a single-page skeleton with mock data and no real investment intelligence. Per the project spec, the terminal must deliver multi-region real-time market data, buy/sell/hold recommendations, rich visualizations, and a polished Apple-like UI across multiple pages — making it genuinely useful to both investment professionals and casual investors.

## What Changes

- Add multi-page navigation (Dashboard, US Markets, Japan Markets, Europe Markets, Recommendations)
- Integrate real-time Alpha Vantage data across all market pages
- Implement buy/sell/hold recommendation engine based on real market signals
- Add rich charts and flow diagrams on all market and recommendation pages
- Polish UI to Apple-level quality with consistent light/dark mode across all pages
- Add an Instructions.md user guide for API setup and application usage
- Expand tests to cover all new pages, routes, and recommendation logic
- Update Makefile with all new run/test/maintenance commands
- Update README.md and DEVELOPER.md to reflect full application

## Capabilities

### New Capabilities
- `multi-page-navigation`: Multiple routes and views for Dashboard, US, Japan, Europe, and Recommendations
- `realtime-market-data`: Live Alpha Vantage data feed for US, Japan, and Europe indices/symbols
- `recommendation-engine`: Buy/sell/hold signal logic based on market data analysis
- `charts-and-visualizations`: Rich charts (line, bar, candlestick) and flow diagrams per market/recommendation
- `instructions-guide`: Instructions.md for users on API setup, supported symbols, and application use

### Modified Capabilities
- `ux-theming`: Extend light/dark mode and Apple-style design across all new pages and components
- `testing`: Add integration and smoke tests for all new routes and recommendation engine
- `documentation`: Update README.md, DEVELOPER.md to cover all pages and features
- `makefile-support`: Add new Makefile targets for multi-page development

## Impact

- New Sinatra routes and ERB views for each market region and recommendations
- New Ruby service for recommendation logic
- Alpha Vantage API expanded to cover multiple symbols and regions
- Chart.js expanded with more chart types
- All documentation updated
