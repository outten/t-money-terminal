## Context

The project aims to reimagine the Bloomberg Terminal for the modern era, leveraging open-source technologies and public/global market data. The current state is a greenfield project with no existing codebase. Stakeholders include investment professionals, casual investors, and developers interested in financial technology.

## Goals / Non-Goals

**Goals:**
- Deliver a proof-of-concept terminal with a clean, user-friendly UI (Apple-like)
- Integrate mock and/or real public market data (US, Japan, Europe)
- Provide light/dark mode and basic charting
- Establish strong documentation and automated testing
- Enable easy setup and maintenance via Makefile

**Non-Goals:**
- Not aiming for feature parity with Bloomberg Terminal
- No proprietary or paid data integrations in the initial phase
- No mobile or desktop native apps (web only for now)

## Decisions

- Use Ruby and Sinatra for rapid prototyping and simplicity
- Use mock data initially, with option to swap in real APIs
- Prioritize usability and clarity in UI/UX (light/dark mode, charts)
- Use open-source charting libraries (e.g., Chart.js or similar)
- Documentation and tests are first-class citizens
- Makefile will orchestrate setup, run, and test tasks

## Risks / Trade-offs

- [Risk] Real market data APIs may have rate limits or costs → Mitigation: Start with mock data, document API requirements
- [Risk] Ruby/Sinatra may limit scalability for future growth → Mitigation: Focus on proof-of-concept, design for modularity
- [Risk] UI/UX polish may require more time than expected → Mitigation: Start with a simple, clean skeleton and iterate

## Migration Plan

- N/A (greenfield project)

## Open Questions

- Which public APIs offer the best free/low-cost global market data?
- What charting library best fits the tech stack and UX goals?
- Should we consider a frontend framework (e.g., React) for future phases?
