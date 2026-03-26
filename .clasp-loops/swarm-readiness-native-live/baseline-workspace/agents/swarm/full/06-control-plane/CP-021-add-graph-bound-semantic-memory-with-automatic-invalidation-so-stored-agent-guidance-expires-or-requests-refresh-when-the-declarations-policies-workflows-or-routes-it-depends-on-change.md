# CP-021 Add Graph-Bound Semantic Memory With Automatic Invalidation So Stored Agent Guidance Expires Or Requests Refresh When The Declarations, Policies, Workflows, Or Routes It Depends On Change

## Goal

Add graph-bound semantic memory with automatic invalidation so stored agent guidance expires or requests refresh when the declarations, policies, workflows, or routes it depends on change

## Why

The agent platform only becomes real when permissions, commands, hooks, agents, and policies are first-class declarations. This task belongs to the Control Plane Declarations track.

## Scope

- Implement `CP-021` as one narrow slice of work: Add graph-bound semantic memory with automatic invalidation so stored agent guidance expires or requests refresh when the declarations, policies, workflows, or routes it depends on change
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

- `CP-020`

## Acceptance

- `CP-021` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
