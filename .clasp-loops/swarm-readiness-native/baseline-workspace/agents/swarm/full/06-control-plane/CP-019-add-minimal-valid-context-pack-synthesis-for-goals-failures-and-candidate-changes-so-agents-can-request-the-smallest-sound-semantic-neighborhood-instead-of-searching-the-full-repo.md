# CP-019 Add Minimal Valid Context-Pack Synthesis For Goals, Failures, And Candidate Changes So Agents Can Request The Smallest Sound Semantic Neighborhood Instead Of Searching The Full Repo

## Goal

Add minimal valid context-pack synthesis for goals, failures, and candidate changes so agents can request the smallest sound semantic neighborhood instead of searching the full repo

## Why

The agent platform only becomes real when permissions, commands, hooks, agents, and policies are first-class declarations. This task belongs to the Control Plane Declarations track.

## Scope

- Implement `CP-019` as one narrow slice of work: Add minimal valid context-pack synthesis for goals, failures, and candidate changes so agents can request the smallest sound semantic neighborhood instead of searching the full repo
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

- `CP-018`

## Acceptance

- `CP-019` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
