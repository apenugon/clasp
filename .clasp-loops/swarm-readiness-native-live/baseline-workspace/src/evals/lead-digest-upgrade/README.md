# Lead Digest Upgrade Eval

This is a small, current-state eval slice for `Clasp`.

It is intentionally narrow:

- two modules
- one typed route
- one typed tool boundary
- one workflow state contract
- one coordinated schema upgrade task

The point is to test a real cross-surface product change with the compiler and runtime surfaces that already work today.

## Why this slice

This task is meant to show whether `Clasp` can help an agent handle a coordinated contract change without falling into schema drift.

The task requires updating:

- shared record schemas
- one route contract
- one tool request contract
- one workflow state schema
- one consumer path that still has to execute cleanly

## Layout

- `TASK.md`: the task prompt an agent would receive
- `start/`: the starting state for the task
- `solution/`: a known-good target state
- `baseline-validate.sh`: compile-plus-main-only baseline validator
- `validate.sh`: build-and-validate entrypoint for a candidate directory
- `validate.mjs`: semantic validator for already-built artifacts
- `compare.sh`: emits local `raw repo` vs `Clasp-aware` comparison metrics for this eval
- `run-live-codex.sh`: runs one live `Codex` comparison for `raw-repo` vs `Clasp-aware`
- `test.sh`: proves the eval works by checking that `start/` fails target validation and `solution/` passes

## How to run

From the repository root:

```bash
bash src/evals/lead-digest-upgrade/test.sh
```

Or validate a candidate directory directly:

```bash
bash src/evals/lead-digest-upgrade/validate.sh \
  src/evals/lead-digest-upgrade/solution
```

To emit the local comparison metrics:

```bash
bash src/evals/lead-digest-upgrade/compare.sh
```

To run one live `Codex` comparison and write result files under `results/`:

```bash
bash src/evals/lead-digest-upgrade/run-live-codex.sh
```

## Notes

This eval currently uses the already-built bootstrap `claspc` binary from `dist-newstyle`.

That is deliberate:

- it exercises the richer route/tool/workflow surface that exists today
- it avoids requiring `cabal` or `nix` in this environment
- it keeps the eval runnable inside the current checkout
- the shell wrapper handles compilation because this sandbox reports a spurious `EPERM` when `Node` tries to spawn the compiler directly

## Current Metric Shape

This eval now exposes two local comparison modes:

- `raw repo`: task plus source files, with a baseline validator that only checks compile success and `main`
- `Clasp-aware`: task plus a compact compiler-derived semantic brief, with a validator that also checks schema, route, tool, workflow, context-graph, and AIR propagation

Those are not full agent benchmark metrics yet. They are local, reproducible leverage metrics for the same task slice:

- rough prompt payload size
- observable surface count
- start-state failure signal count
- exact changed-file count for the oracle target

The live `Codex` runner adds actual harness metrics for this same eval:

- duration
- total tokens
- uncached tokens
- verify attempts
- repair loops
- time-to-green when the agent runs verification before finishing
