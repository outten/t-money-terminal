## MODIFIED Requirements

### Requirement: Multi-page navigation with symbol analysis routing
The system SHALL render a navigation bar on all pages. The navigation SHALL include Dashboard, US Markets, Japan Markets, and Europe Markets. The Recommendations nav item SHALL be removed. Every symbol displayed in the application SHALL be a clickable link navigating to `/analysis/:symbol`. Region labels in the dashboard table SHALL be clickable links navigating to `/region/:name` (e.g., "US" links to `/region/us`).

#### Scenario: Nav does not include Recommendations
- **WHEN** any page loads
- **THEN** the navigation bar does not show a Recommendations link

#### Scenario: Symbol links navigate to analysis page
- **WHEN** the user clicks a symbol (e.g., "AAPL") anywhere in the application
- **THEN** the browser navigates to `/analysis/AAPL`

#### Scenario: Region label is a link
- **WHEN** the user views the dashboard symbol table
- **THEN** each region value (e.g., "US", "Japan", "Europe") is a clickable link to its region page (e.g., `/region/us`)

#### Scenario: Dashboard shows recommendations section
- **WHEN** the user loads the Dashboard
- **THEN** a Market Signals section is visible below the summary table, showing signal cards for all tracked symbols with price, change, analyst counts summary, and a "View Analysis →" link

#### Scenario: Active nav item is highlighted
- **WHEN** the user is on a specific page
- **THEN** the corresponding navigation item is visually highlighted
