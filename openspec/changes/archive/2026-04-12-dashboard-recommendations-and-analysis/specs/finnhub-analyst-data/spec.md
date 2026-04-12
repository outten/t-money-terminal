## ADDED Requirements

### Requirement: Finnhub analyst recommendation fetch
The system SHALL fetch analyst recommendation data from Finnhub (`/stock/recommendation`) for a given symbol, returning the most recent monthly snapshot's Strong Buy, Buy, Hold, Sell, and Strong Sell counts. Results SHALL be cached for 24 hours.

#### Scenario: Analyst data fetched and cached
- **WHEN** analyst data is requested for a symbol not in cache
- **THEN** the system calls Finnhub `/stock/recommendation`, caches the result for 24 hours, and returns the most recent snapshot

#### Scenario: Finnhub key absent
- **WHEN** FINNHUB_API_KEY is not set
- **THEN** the method returns nil and does not make an HTTP call

### Requirement: Finnhub company profile fetch
The system SHALL fetch company/ETF profile data from Finnhub (`/stock/profile2`) for a given symbol, returning name, description, exchange, industry, market cap, and IPO date where available. Results SHALL be cached for 24 hours.

#### Scenario: Profile fetched and cached
- **WHEN** profile data is requested for a symbol not in cache
- **THEN** the system calls Finnhub `/stock/profile2`, caches the result for 24 hours, and returns the profile hash

#### Scenario: Empty profile for ETF
- **WHEN** Finnhub returns an empty or minimal profile for an ETF symbol
- **THEN** the system returns the partial data; callers supplement with hardcoded ETF descriptions

### Requirement: Historical candle data fetch
The system SHALL fetch historical OHLCV candle data for a given symbol and period (1D, 1M, 3M, YTD, 1Y, 5Y) from Yahoo Finance as primary source, falling back to Finnhub `/stock/candle`. Results SHALL be cached for 24 hours.

#### Scenario: Historical data returned for valid period
- **WHEN** historical data is requested for a symbol and period
- **THEN** the system returns an array of `{ date, close }` data points for that period

#### Scenario: All sources fail
- **WHEN** both Yahoo Finance and Finnhub candle endpoints fail or return no data
- **THEN** the method returns nil and the caller renders a no-data notice
