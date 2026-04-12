## MODIFIED Requirements

### Requirement: Integrate public/global market data
The system SHALL fetch and display live market data from Alpha Vantage for US, Japan, and Europe when `ALPHA_VANTAGE_API_KEY` is present in the environment. When the key is absent or a fetch fails, the system SHALL fall back to mock data AND emit a warning to stderr explaining why mock data is being used.

#### Scenario: Market data visible
- **WHEN** the user accesses the dashboard
- **THEN** market data for multiple regions is displayed in charts or tables

#### Scenario: Live data fetched when API key present
- **WHEN** `ALPHA_VANTAGE_API_KEY` is set in the environment AND a quote is requested for a symbol not yet in cache
- **THEN** the system makes an HTTP request to Alpha Vantage and returns the real price data

#### Scenario: Warning emitted when API key is missing
- **WHEN** `ALPHA_VANTAGE_API_KEY` is not set in the environment
- **THEN** the system warns to stderr that the API key is missing and mock data will be used (warning is suppressed in the test environment)

#### Scenario: Warning emitted on fetch failure
- **WHEN** `ALPHA_VANTAGE_API_KEY` is set but the Alpha Vantage request fails (network error, rate limit, bad response)
- **THEN** the system warns to stderr with the failure reason and returns mock data for the affected symbol
