## ADDED Requirements

### Requirement: Auto-reloading development server
The system SHALL provide a `make dev` target that starts the Sinatra application wrapped with `rerun` so the server automatically restarts whenever source files change.

#### Scenario: Dev target starts app with rerun
- **WHEN** the developer runs `make dev` in the project root
- **THEN** the server starts on port 4567 and file changes trigger automatic restart without manual intervention

#### Scenario: Production run target is unchanged
- **WHEN** the developer runs `make run`
- **THEN** the server starts without rerun wrapping, matching the production invocation
