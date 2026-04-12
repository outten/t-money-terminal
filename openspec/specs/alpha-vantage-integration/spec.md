# alpha-vantage-integration Specification

## Purpose
Alpha Vantage API integration as the primary real-time market data provider.

## Requirements

### Requirement: Integrate Alpha Vantage for real-time data
The system SHALL support fetching real-time market data using the Alpha Vantage API when ALPHA_VANTAGE_API_KEY is configured.

#### Scenario: Fetch real-time quote
- **WHEN** ALPHA_VANTAGE_API_KEY is set in the environment AND a quote is requested for a symbol
- **THEN** the system attempts to return data from Alpha Vantage before falling back to other providers
