# WF-010 Add Supervisor Hierarchy Declarations And Restart Strategies Inspired By Erlang/BEAM

## Goal

Add supervisor hierarchy declarations and restart strategies inspired by Erlang/BEAM.

## Why

Long-running agent systems need durable state, replay, and supervised self-update before Clasp can claim real autonomy. This task belongs to the Durable Workflows And Hot Swap track.

## Scope

- Add one level of supervisor hierarchy declarations for long-running workflows.
- Support a small fixed restart-strategy set in this slice: `one_for_one` and `one_for_all`.
- Add one checked-in demo under `examples/supervision-demo/` that shows a child workflow failure and the resulting supervised restart behavior.
- Keep the runtime model local and explicit. This task does not need distributed nodes, transparent message passing, or a general actor runtime.
- Add or update regression coverage for parsing, checking, lowered/runtime behavior, and the demo restart path.
- Update docs or examples only where the new surface changes visible behavior.
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/Clasp/Syntax.hs`
- `src/Clasp/Parser.hs`
- `src/Clasp/Checker.hs`
- `src/Clasp/Core.hs`
- `src/Clasp/Lower.hs`
- `runtime/`
- `examples/supervision-demo/`
- `test/Main.hs`
- `docs/clasp-project-plan.md`

## Dependencies

- `WF-009`

Assume `WF-001` through `WF-009` have already landed workflow declarations, checkpointing, replay, upgrade metadata, and supervised hot-swap handoff.

## Acceptance

- Supervisor hierarchy declarations parse and typecheck.
- `one_for_one` and `one_for_all` restart behavior is implemented for the demo path.
- A checked-in demo exists at `examples/supervision-demo/` and shows supervised recovery from a child failure.
- Tests or regressions cover declaration shape and restart behavior.
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
