## MODIFIED Requirements

### Requirement: BUY/SELL/HOLD signal generation
The system SHALL derive BUY/SELL/HOLD signals using Finnhub analyst consensus as the primary source. For symbols with analyst data, the signal SHALL be computed from the most recent monthly snapshot: if `strongBuy + buy > strongSell + sell + (hold / 2)` the signal is BUY; if `strongSell + sell > strongBuy + buy + (hold / 2)` the signal is SELL; otherwise HOLD. For symbols without analyst data (e.g., ETFs), the system SHALL fall back to the price-change-% momentum signal and label it as "Momentum" rather than "Analyst Consensus".

#### Scenario: Analyst consensus signal for equity
- **WHEN** Finnhub analyst data is available for the symbol
- **THEN** the signal is derived from analyst counts and labeled "Analyst Consensus"

#### Scenario: Momentum fallback for ETF
- **WHEN** Finnhub returns no analyst data for the symbol
- **THEN** the signal is derived from price change % and labeled "Momentum Signal"

#### Scenario: Signals available for all tracked symbols
- **WHEN** signals are requested for all tracked symbols
- **THEN** each symbol returns a valid BUY, SELL, or HOLD signal with a signal type label
