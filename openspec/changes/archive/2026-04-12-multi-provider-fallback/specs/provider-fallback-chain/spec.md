## ADDED Requirements

### Requirement: Ordered provider fallback chain
The system SHALL attempt to fetch a quote from Alpha Vantage first, then Finnhub, then Yahoo Finance, in that fixed order. The first provider that returns a valid non-empty quote SHALL be used and the result cached. If all three providers fail, the system SHALL fall back to mock data and emit a warning to stderr.

#### Scenario: Alpha Vantage succeeds
- **WHEN** Alpha Vantage returns a non-empty Global Quote response for a symbol
- **THEN** that quote is used and no subsequent providers are tried

#### Scenario: Alpha Vantage empty, Finnhub succeeds
- **WHEN** Alpha Vantage returns an empty or invalid response AND Finnhub returns a valid quote
- **THEN** the Finnhub quote is used and a warning is emitted naming Alpha Vantage as failed

#### Scenario: Alpha Vantage and Finnhub fail, Yahoo Finance succeeds
- **WHEN** both Alpha Vantage and Finnhub fail or return empty responses AND Yahoo Finance returns a valid quote
- **THEN** the Yahoo Finance quote is used and warnings are emitted for each failed provider

#### Scenario: All providers fail
- **WHEN** Alpha Vantage, Finnhub, and Yahoo Finance all fail or return empty responses
- **THEN** mock data is used and a warning naming all three providers as failed is emitted to stderr

### Requirement: Provider response normalization
The system SHALL normalize quotes from all providers into a consistent internal hash shape with keys `"05. price"`, `"10. change percent"`, and `"06. volume"` so that no callers outside `MarketDataService` require changes.

#### Scenario: Finnhub response normalized
- **WHEN** a quote is fetched from Finnhub (which returns `c`, `dp`, `v` fields)
- **THEN** the result hash exposes `"05. price"`, `"10. change percent"` (with `%` suffix), and `"06. volume"` keys

#### Scenario: Yahoo Finance response normalized
- **WHEN** a quote is fetched from Yahoo Finance
- **THEN** the result hash exposes `"05. price"`, `"10. change percent"` (with `%` suffix), and `"06. volume"` keys

### Requirement: Finnhub provider activation
The system SHALL only attempt to fetch from Finnhub when `FINNHUB_API_KEY` is present in the environment. If the key is absent, Finnhub SHALL be silently skipped in the provider chain.

#### Scenario: Finnhub skipped when key absent
- **WHEN** `FINNHUB_API_KEY` is not set in the environment
- **THEN** Finnhub is not called and the chain proceeds directly to Yahoo Finance
