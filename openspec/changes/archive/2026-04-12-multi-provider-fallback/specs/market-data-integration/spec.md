## MODIFIED Requirements

### Requirement: Integrate public/global market data
The system SHALL fetch and display live market data for US, Japan, and Europe using an ordered provider chain (Alpha Vantage → Finnhub → Yahoo Finance). When all live providers fail or no API keys are configured, the system SHALL fall back to mock data AND emit a warning to stderr. The system SHALL suppress warnings in the test environment (`RACK_ENV=test`).

#### Scenario: Market data visible
- **WHEN** the user accesses the dashboard
- **THEN** market data for multiple regions is displayed in charts or tables

#### Scenario: Live data fetched when at least one provider is available
- **WHEN** at least one provider (Alpha Vantage, Finnhub, or Yahoo Finance) is reachable and returns a valid quote
- **THEN** real price data is displayed for the requested symbol

#### Scenario: Warning emitted when all providers fail
- **WHEN** all providers in the chain fail to return a valid quote
- **THEN** the system warns to stderr and returns mock data for the affected symbol

#### Scenario: Warning suppressed in test environment
- **WHEN** `RACK_ENV` is set to `test`
- **THEN** no warnings are emitted to stderr when falling back to mock data due to a missing API key
