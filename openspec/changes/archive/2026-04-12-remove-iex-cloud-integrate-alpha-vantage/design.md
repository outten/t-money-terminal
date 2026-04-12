## Context

IEX Cloud was retired in August 2024, requiring the removal of all related integration from the application. Alpha Vantage remains as a reliable, free provider for real-time market data. The current state includes both IEX Cloud and Alpha Vantage support, with documentation and tests referencing both.

## Goals / Non-Goals

**Goals:**
- Remove all IEX Cloud integration from backend and frontend
- Ensure Alpha Vantage is the sole real-time data provider
- Update documentation and credentials setup
- Add or update tests for Alpha Vantage integration

**Non-Goals:**
- No support for IEX Cloud or other retired/unsupported APIs
- No changes to unrelated features or data sources

## Decisions

- Remove all IEX Cloud code, UI, and documentation
- Use Alpha Vantage exclusively for real-time data
- Update tests to cover only Alpha Vantage
- Use environment variable for Alpha Vantage API key via dotenv

## Risks / Trade-offs

- [Risk] Users may have relied on IEX Cloud → Mitigation: Clearly document the change and provide migration instructions
- [Risk] Alpha Vantage has rate limits → Mitigation: Document limits and suggest API key registration for all users

## Migration Plan

- Remove IEX Cloud code and references
- Update documentation and tests
- Release as a breaking change

## Open Questions

- Should we provide a fallback or mock data if Alpha Vantage is unavailable?
