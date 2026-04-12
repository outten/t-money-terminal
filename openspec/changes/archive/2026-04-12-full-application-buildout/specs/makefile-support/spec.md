## MODIFIED Requirements

### Requirement: Provide a Makefile for setup and maintenance
The system SHALL include Makefile targets for running the app, running tests, installing dependencies, and any new maintenance tasks added with the full buildout.

#### Scenario: All Makefile targets work
- **WHEN** the user runs make run or make test
- **THEN** the application starts or tests execute successfully
