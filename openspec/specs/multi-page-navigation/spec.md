# multi-page-navigation Specification

## Purpose
Define requirements for multi-page navigation across the application, including a shared layout and navigation bar linking all major pages.

## Requirements

### Requirement: Multi-page navigation
The system SHALL provide a navigation bar with links to Dashboard, US Markets, Japan Markets, Europe Markets, and Recommendations pages, rendered via a shared layout.

#### Scenario: User navigates to a market page
- **WHEN** the user clicks a navigation link
- **THEN** the corresponding market or recommendations page loads with relevant data and charts

#### Scenario: Active nav item is highlighted
- **WHEN** the user is on a specific page
- **THEN** the corresponding navigation item is visually highlighted
