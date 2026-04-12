# realtime-market-data Specification

## Purpose
Define requirements for fetching and displaying real-time or recent market data for US, Japan, and Europe markets using Alpha Vantage, with mock data fallback.

## Requirements

### Requirement: Real-time market data for US, Japan, and Europe
The system SHALL fetch and display real-time or recent market data for US (e.g., SPY, AAPL), Japan (e.g., EWJ), and Europe (e.g., VGK) using Alpha Vantage. When API data is unavailable, mock data SHALL be displayed as fallback with a timestamp indicating last update.

#### Scenario: Real-time data displayed
- **WHEN** the user visits a market page and an Alpha Vantage API key is configured
- **THEN** the page displays live price, change, and volume data for that region's symbols

#### Scenario: Fallback to mock data
- **WHEN** the API key is missing or rate limit is reached
- **THEN** the page displays mock data with a visible "Data may be delayed" notice
