## MODIFIED Requirements

### Requirement: Provide a Makefile for setup and maintenance
The system SHALL include Makefile targets for running the app, running tests, installing dependencies, and any new maintenance tasks added with the full buildout. This SHALL include a `cache-status` target that prints a summary of the current cache state to the terminal without starting the server.

#### Scenario: All Makefile targets work
- **WHEN** the user runs `make run` or `make test`
- **THEN** the application starts or tests execute successfully

#### Scenario: Cache status target prints a summary
- **WHEN** the user runs `make cache-status`
- **THEN** the terminal displays a table of cached keys, their types, timestamps, staleness, and sizes, then exits
