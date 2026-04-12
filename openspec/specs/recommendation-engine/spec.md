# recommendation-engine Specification

## Purpose
Define requirements for a buy/sell/hold recommendation engine based on market signals, with appropriate disclaimers that recommendations are not financial advice.

## Requirements

### Requirement: Buy/sell/hold recommendation engine
The system SHALL provide a buy, sell, or hold recommendation for each tracked symbol based on market signals (e.g., moving average crossover, RSI). All recommendations SHALL be labelled as indicative only, not financial advice.

#### Scenario: Recommendation displayed for a symbol
- **WHEN** the user visits the Recommendations page
- **THEN** each tracked symbol shows a buy, sell, or hold signal with supporting rationale

#### Scenario: Recommendation disclaimer shown
- **WHEN** the Recommendations page is loaded
- **THEN** a disclaimer stating "For informational purposes only. Not financial advice." is prominently displayed
