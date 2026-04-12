## Context

The application currently consists of one page with mock data, a basic bar chart, and a light/dark toggle. The full SPEC.md calls for a rich, multi-page investment terminal with live market data (US, Japan, Europe), buy/sell/hold recommendations, professional charting, and complete documentation. The stack is Ruby/Sinatra with Alpha Vantage for real-time data and Chart.js for visualization.

## Goals / Non-Goals

**Goals:**
- Multi-page app: Dashboard, US Markets, Japan Markets, Europe Markets, Recommendations
- Real-time Alpha Vantage data on all market pages
- Buy/sell/hold recommendation engine based on market signals
- Polished Apple-like UI with light/dark mode everywhere
- Instructions.md user guide
- Full test coverage for all routes and recommendation logic
- Updated Makefile, README.md, DEVELOPER.md

**Non-Goals:**
- No actual trade execution (future phase)
- No user authentication
- No paid/proprietary data sources in this phase
- No mobile native app

## Decisions

- **Multi-page with Sinatra routes**: Each market region and recommendations get their own route and ERB view; shared layout via `layout.erb`
- **Alpha Vantage for all regions**: US symbols (e.g., SPY, AAPL), Japan proxies (e.g., EWJ ETF), Europe proxies (e.g., VGK ETF) — direct Japan/EU exchange APIs require paid access; ETF proxies are free
- **Recommendation engine as a Ruby service**: Simple rule-based signals (RSI, moving average crossover) using Alpha Vantage technical indicator endpoints
- **Chart.js for all charts**: Consistent with existing stack; supports line, bar, candlestick via chartjs-chart-financial plugin
- **Shared layout.erb**: Navigation, theme toggle, and footer in one place; all views extend it

## Risks / Trade-offs

- [Risk] Alpha Vantage free tier is limited to 25 requests/day → Mitigation: Cache responses in memory; display last-known data with timestamp
- [Risk] Japan/Europe real-time data via ETF proxies may lag → Mitigation: Document the proxy approach clearly; note it as POC limitation
- [Risk] Recommendation engine accuracy is POC-level only → Mitigation: Label all signals as "indicative, not financial advice"

## Migration Plan

- Existing single page becomes the Dashboard route
- Mock data stays as fallback when API key is missing or rate limit hit
- All new views added without touching existing code paths

## Open Questions

- Should we show real-time price streaming (websocket) or polling? → Start with polling (Alpha Vantage REST)
- Should recommendations be cached between requests? → Yes, cache for 24 hours; a manual cache-refresh script is available via `make refresh-cache`
