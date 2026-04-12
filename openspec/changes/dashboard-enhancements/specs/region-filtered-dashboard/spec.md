## ADDED Requirements

### Requirement: Region-filtered dashboard page
The system SHALL provide `GET /region/:name` routes for each named region (us, japan, europe). Each route SHALL render a page that shows the same enriched symbol table as the main dashboard but filtered to only symbols belonging to that region. Unknown region names SHALL return HTTP 404.

#### Scenario: Valid region page loads
- **WHEN** the user navigates to `/region/us`
- **THEN** the page renders a symbol table containing only US equities and ETFs with price, change, type, and signal columns

#### Scenario: Unknown region returns 404
- **WHEN** the user navigates to `/region/unknown`
- **THEN** the server returns HTTP 404

#### Scenario: Region page matches dashboard table structure
- **WHEN** the user views any region page
- **THEN** the table columns (Symbol, Type, Price, Change, Signal, View) match those on the main dashboard
