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

## Contributing

The full PR workflow (branch naming, commit style, PR body template, CI,
rebase-merge) lives in [CONTRIBUTING.md](CONTRIBUTING.md).
