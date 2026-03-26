# Benchmark Agent Advantage Wave v0

This wave is the next implementation pass aimed directly at improving `Clasp` on the mirrored lead-inbox benchmark, not just at making the benchmark fairer.

It focuses on the roadmap items that should most reduce agent work on the current `lead-segment` class of task:

- compiler-known graph identity through `AIR`
- structured page, route, and form/action contracts
- structured host-boundary contracts
- explicit trusted versus untrusted boundary data
- queryable context and UI/action graphs
- semantic edit or refactor operations over those compiler-known artifacts

The benchmark now has two official modes:

- `Raw Repo`
- `File-Hinted`

This wave should help `Clasp` in both modes:

- in `Raw Repo` by improving discovery, bounding, and machine-readable context
- in `File-Hinted` by improving propagation, editing, and verification once the agent is on the right files

This wave intentionally uses canonical backlog task IDs directly so completed work becomes part of the shared global dependency graph instead of living behind a wave-local prefix.

Lanes in this wave:

- `01-air-core`
- `02-app-flow-contracts`
- `03-host-boundaries`
- `04-context-graph`
- `05-ui-graph`
- `06-semantic-edits`

Dependency flow:

- `TY-015` starts immediately.
- `FS-013` starts immediately, then `FS-014` builds on it in the same lane.
- `FS-011` starts immediately, then `SC-013` builds on it in the same lane.
- `FS-015` depends on `FS-013` and `FS-014`.
- `CP-013` depends on `TY-015`, `FS-013`, `FS-014`, `FS-011`, and `SC-013`.
- `TY-014` depends on `TY-015`, `CP-013`, and `FS-015`.

Success for this wave means:

- an agent can query the compiler for the relevant schema, route, page, action, and boundary surfaces instead of grepping blindly
- the benchmark app exposes machine-readable UI/action/context artifacts
- the path from a shared contract change to affected declarations is more compiler-owned and less text-hunt-driven
- the next `Raw Repo` and `File-Hinted` reruns measure more of the language and less of missing semantic tooling
