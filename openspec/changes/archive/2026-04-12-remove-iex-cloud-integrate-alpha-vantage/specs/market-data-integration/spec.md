## MODIFIED Requirements

### Requirement: Market data integration
The system SHALL NOT use IEX Cloud for any data. The system SHALL use Alpha Vantage as the sole real-time data provider.

#### Scenario: Only Alpha Vantage is used
- **WHEN** the user requests real-time data
- **THEN** the system fetches from Alpha Vantage and does not reference IEX Cloud
