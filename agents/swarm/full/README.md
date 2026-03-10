# Full Backlog

This wave materializes the full Clasp project backlog from `docs/clasp-project-plan.md`.

It is the intended default swarm target once the current `wave1` work is merged forward.

The swarm waits for every dependency listed in a task file before starting that task.

Lanes in this wave:

- `01-swarm-infra`: Swarm Infrastructure (8 tasks)
- `02-core-language`: Core Language Surface (19 tasks)
- `03-type-system`: Type System And Diagnostics (10 tasks)
- `04-schemas`: Schemas And Trust Boundaries (13 tasks)
- `05-full-stack`: Full-Stack Runtime And App Layer (10 tasks)
- `06-control-plane`: Control Plane (12 tasks)
- `07-workflows`: Durable Workflows And Hot Swap (13 tasks)
- `08-ai-platform`: AI-Native Platform (12 tasks)
- `09-external-objectives`: External-Objective Adaptation (7 tasks)
- `10-benchmarks`: Benchmark Program (15 tasks)
- `11-saas-dogfood`: SaaS Dogfooding (10 tasks)
- `12-self-hosting`: Self-Hosting (10 tasks)
- `13-native-backend`: Native Backend And Bytecode (8 tasks)
- `14-sqlite`: SQLite Storage (6 tasks)

Total tasks: 153

Regenerate with:

```sh
node scripts/materialize-full-backlog.mjs
```

