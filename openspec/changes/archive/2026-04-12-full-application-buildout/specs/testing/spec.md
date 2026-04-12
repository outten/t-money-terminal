## MODIFIED Requirements

### Requirement: Automated tests for core features
The system SHALL include smoke and integration tests for all routes (Dashboard, US, Japan, Europe, Recommendations), the recommendation engine, and Alpha Vantage data service. Tests SHALL be runnable via the Makefile.

#### Scenario: All routes respond successfully
- **WHEN** tests are run
- **THEN** all application routes return HTTP 200

#### Scenario: Recommendation engine returns valid signals
- **WHEN** tests are run with mock data
- **THEN** the recommendation engine returns buy, sell, or hold for each symbol
