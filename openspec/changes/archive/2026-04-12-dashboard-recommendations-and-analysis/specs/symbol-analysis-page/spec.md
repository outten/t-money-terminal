## ADDED Requirements

### Requirement: Per-symbol analysis page
The system SHALL provide a `GET /analysis/:symbol` route that renders a full research page for any known symbol. Unknown symbols SHALL return HTTP 404.

#### Scenario: Valid symbol returns analysis page
- **WHEN** the user navigates to `/analysis/AAPL`
- **THEN** the page renders with analyst consensus, company profile, financials, historical charts, and source citations for AAPL

#### Scenario: Unknown symbol returns 404
- **WHEN** the user navigates to `/analysis/INVALID`
- **THEN** the server returns HTTP 404

### Requirement: Analyst consensus section
The analysis page SHALL display the most recent monthly analyst recommendation breakdown from Finnhub, showing counts for Strong Buy, Buy, Hold, Sell, and Strong Sell, plus the derived overall signal (BUY/SELL/HOLD). The data source (Finnhub) SHALL be cited.

#### Scenario: Analyst data available
- **WHEN** Finnhub returns analyst recommendation data for the symbol
- **THEN** the page displays the breakdown counts and overall signal, with "Source: Finnhub" citation

#### Scenario: No analyst data (ETF)
- **WHEN** Finnhub returns empty analyst data for the symbol (e.g., an ETF)
- **THEN** the page displays a momentum-based signal with a note that analyst consensus is unavailable for this instrument

### Requirement: Company and fund profile section
The analysis page SHALL display the symbol's company or fund profile including name, description, exchange, industry/category, market cap, PE ratio, 52-week high/low, and IPO date (where available). Links to Google Finance and Yahoo Finance SHALL be provided and SHALL open in a new tab. The data source SHALL be cited.

#### Scenario: Profile displayed with source link
- **WHEN** the user views the analysis page for any symbol
- **THEN** a profile section is visible showing available company/fund metadata, with Google Finance and Yahoo Finance links that open in a new tab
- **AND** the data source is cited (Finnhub or hardcoded for known ETFs)

### Requirement: Historical price charts with period toggle
The analysis page SHALL display a historical price chart with selectable periods: 1D, 1M, 3M, YTD, 1Y, 5Y. The chart SHALL be rendered via Chart.js. The source of historical data SHALL be cited.

#### Scenario: Period toggle updates chart
- **WHEN** the user clicks a period button (e.g., "1Y")
- **THEN** the chart updates to show price history for that period without a full page reload

#### Scenario: Historical data unavailable
- **WHEN** all historical data sources fail for a given symbol and period
- **THEN** a "Historical data unavailable" notice is shown in place of the chart

### Requirement: Source citations on analysis page
Every data section on the analysis page SHALL display a visible citation indicating its data source (e.g., "Source: Finnhub", "Source: Yahoo Finance", "Source: Alpha Vantage").

#### Scenario: Citations visible
- **WHEN** the user views any section of the analysis page
- **THEN** a source citation is present for that section's data

### Requirement: Legacy recommendations route redirect
`GET /recommendations` SHALL return a 301 redirect to `/dashboard`.

#### Scenario: Old URL redirects
- **WHEN** the user navigates to `/recommendations`
- **THEN** they are redirected to `/dashboard`
