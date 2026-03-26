# Selfhost Native Endgame Wave v0

This wave is the focused endgame pass for the three remaining milestones on the path to fully self-hosted, fully native `Clasp`:

- finish hosted compiler takeover for ordinary compiler workflows
- run the self-hosted compiler through the native backend
- remove server-side JavaScript runtime dependence from the compiler/server loop, leaving JavaScript only as an emitted client target

It intentionally uses canonical backlog task IDs directly, so any already-landed work still counts toward the shared dependency graph instead of being hidden behind wave-local aliases.

This wave snapshots the endgame tasks for:

- `SH-011` through `SH-014`
- `NB-007` through `NB-009`
- `BM-014`

Current wave size:

- `8` canonical tasks

Lanes in this wave:

- `01-hosted-takeover` with `SH-011` and `SH-012`
- `02-bootstrap-quarantine` with `SH-013` and `SH-014`
- `03-native-execution` with `NB-007` through `NB-009`
- `04-native-benchmarks` with `BM-014`

Dependency flow:

- `SH-011` starts once `SH-010` is satisfied in the shared graph.
- `SH-012` depends on `SH-011`.
- `SH-013` depends on `SH-012`.
- `SH-014` depends on `SH-013`.
- `NB-007` depends on `NB-006`, but this wave treats hosted takeover as the practical prerequisite for meaningful native self-hosting.
- `NB-008` depends on `NB-007`.
- `NB-009` depends on `NB-008`.
- `BM-014` depends on `NB-008`.

Success for this wave means:

- ordinary `check`, `compile`, and `explain` flows are Clasp-owned rather than still defaulting to the bootstrap path
- the Haskell bootstrap compiler is quarantined behind explicit recovery-only usage instead of silently carrying normal workflows
- the self-hosted compiler can execute through the native backend
- the repo has benchmark evidence comparing JS/Bun and native on the same compiler/backend workloads
- the remaining server-side JavaScript dependency is no longer the ordinary compiler/runtime path

This wave is narrower than `native-backend-v0`: it is not trying to relitigate the whole dependency closure, only to finish the compiler-takeover and native-execution endgame with canonical tasks.
