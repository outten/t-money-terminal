## Why

IEX Cloud was retired in August 2024, making its integration obsolete. The application must remove all IEX Cloud functionality and focus on Alpha Vantage for real-time market data. This ensures continued access to live data and simplifies API management for users.

## What Changes

- **BREAKING**: Remove all IEX Cloud integration from backend and frontend
- Update documentation and credentials instructions to remove IEX Cloud references
- Ensure Alpha Vantage is the sole real-time data provider
- Add or update tests to verify Alpha Vantage integration

## Capabilities

### New Capabilities
- `alpha-vantage-integration`: Fetch and display real-time market data using Alpha Vantage API only

### Modified Capabilities
- `market-data-integration`: Remove IEX Cloud, update requirements for Alpha Vantage only
- `documentation`: Update setup and credentials docs to reflect Alpha Vantage as the only provider
- `testing`: Add/modify tests to cover Alpha Vantage integration and removal of IEX Cloud

## Impact

- Removal of all IEX Cloud code and UI
- Updated documentation and credentials setup
- Alpha Vantage as the exclusive real-time data source
- Updated and new tests for Alpha Vantage integration
