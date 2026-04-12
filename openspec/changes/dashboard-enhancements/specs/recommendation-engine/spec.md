## MODIFIED Requirements

### Requirement: BUY/SELL/HOLD signal generation
The system SHALL derive BUY/SELL/HOLD signals using a weighted-average analyst score as the primary source. For symbols with analyst data, the score SHALL be computed from the most recent monthly snapshot using: `score = (strongBuy × 2 + buy × 1 + hold × 0 + sell × −1 + strongSell × −2) / total_votes`. If `score > 0.5` the signal is BUY; if `score < −0.5` the signal is SELL; otherwise HOLD. The signal detail hash SHALL include the raw score value. For symbols without analyst data (e.g., ETFs), the system SHALL fall back to the price-change-% momentum signal and label it as "Momentum" rather than "Analyst Consensus".

#### Scenario: Analyst consensus signal for equity
- **WHEN** Finnhub analyst data is available for the symbol
- **THEN** the signal is derived from the weighted analyst score and labeled "Analyst Consensus"
- **AND** the signal detail includes the numeric score value

#### Scenario: Strong consensus yields BUY
- **WHEN** the weighted score exceeds 0.5
- **THEN** the signal is BUY

#### Scenario: Split consensus yields HOLD
- **WHEN** the weighted score is between −0.5 and 0.5 inclusive
- **THEN** the signal is HOLD

#### Scenario: Momentum fallback for ETF
- **WHEN** Finnhub returns no analyst data for the symbol
- **THEN** the signal is derived from price change % and labeled "Momentum Signal"

#### Scenario: Signals available for all tracked symbols
- **WHEN** signals are requested for all tracked symbols
- **THEN** each symbol returns a valid BUY, SELL, or HOLD signal with a signal type label
