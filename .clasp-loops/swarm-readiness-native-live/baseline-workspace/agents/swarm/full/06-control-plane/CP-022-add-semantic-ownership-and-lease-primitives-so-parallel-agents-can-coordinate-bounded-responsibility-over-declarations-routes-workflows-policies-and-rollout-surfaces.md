# CP-022 Add Semantic Ownership And Lease Primitives So Parallel Agents Can Coordinate Bounded Responsibility Over Declarations, Routes, Workflows, Policies, And Rollout Surfaces

## Goal

Add semantic ownership and lease primitives so parallel agents can coordinate bounded responsibility over declarations, routes, workflows, policies, and rollout surfaces

## Why

The agent platform only becomes real when permissions, commands, hooks, agents, and policies are first-class declarations. This task belongs to the Control Plane Declarations track.

## Scope

- Implement `CP-022` as one narrow slice of work: Add semantic ownership and lease primitives so parallel agents can coordinate bounded responsibility over declarations, routes, workflows, policies, and rollout surfaces
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

- `CP-021`

## Acceptance

- `CP-022` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
