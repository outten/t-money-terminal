# Developer Guide

This file is kept as a stable entry point for contributors looking for a
"developer guide" doc. The actual content has consolidated into:

- **[AGENTS.md](AGENTS.md)** — architecture, caching contract, store inventory,
  provider waterfall, common gotchas, project structure, testing notes.
- **[README.md](README.md)** — feature surface, page list, getting started.
- **[CREDENTIALS.md](CREDENTIALS.md)** — API keys, env vars, FMP free-tier
  paywall behaviour, alert-delivery configuration.
- **[Instructions.md](Instructions.md)** — user-facing how-to (running, importing
  Fidelity exports, refreshing caches, alerts).
- **[TODO.md](TODO.md)** — roadmap (shipped + open + dropped).

Start with [AGENTS.md](AGENTS.md) if you're modifying code; everything load-bearing
about how the cache contract, provider waterfall, and store conventions work
lives there.

## Quick reference

```bash
make install                      # bundle install
make run                          # dev server with rerun auto-reload
make test                         # 356 examples (RSpec)
make refresh-all                  # warm every cache for the symbol universe
make scheduler TIER=quotes        # tiered cache refresh
make check-alerts                 # evaluate active price alerts
```

## Contribution

- Fork, branch, and submit PRs against `main`.
- CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs RSpec + scripts
  syntax check on every PR.
- **Update relevant docs in the same PR.** Don't leave docs to be reconciled
  later — they drift silently. Touchpoints: README, CREDENTIALS, TODO, AGENTS,
  Instructions.
- Tests are required for new behaviour. Particularly: anything that could
  break the [cache-only render contract](AGENTS.md#caching-architecture) needs
  hard `not_to receive(:fetch_quote)` assertions like the ones in
  [spec/portfolio_perf_spec.rb](spec/portfolio_perf_spec.rb).
