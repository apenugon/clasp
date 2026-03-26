# CP-024 Add Interference And Commutativity Analysis For Candidate Changes And Parallel Workstreams So The Compiler Can Decide When Plans Can Proceed Independently And When They Must Serialize

## Goal

Add interference and commutativity analysis for candidate changes and parallel workstreams so the compiler can decide when plans can proceed independently and when they must serialize

## Why

The agent platform only becomes real when permissions, commands, hooks, agents, and policies are first-class declarations. This task belongs to the Control Plane Declarations track.

## Scope

- Implement `CP-024` as one narrow slice of work: Add interference and commutativity analysis for candidate changes and parallel workstreams so the compiler can decide when plans can proceed independently and when they must serialize
- Add or update regression coverage for the new behavior
- If the task changes runtime behavior, trust boundaries, workflows, interop, or app/user-facing execution surfaces, add or update at least one scenario-level or end-to-end verification path
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/Clasp/`
- `runtime/`
- `scripts/`
- `docs/`
- `agents/`
- `test/Main.hs`

## Dependencies

- `CP-023`

## Acceptance

- `CP-024` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
