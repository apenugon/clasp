# BM-041 Add Agent-Runtime Benchmarks Proving Subagent Contract Safety, Delegated-Capability Containment, Plugin Or Hook ABI Compatibility, Session Resumability, Approval-Flow Correctness, And Host-Surface Patch Lifecycle Integrity

## Goal

Add agent-runtime benchmarks proving subagent contract safety, delegated-capability containment, plugin or hook ABI compatibility, session resumability, approval-flow correctness, and host-surface patch lifecycle integrity

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-041` as one narrow slice of work: Add agent-runtime benchmarks proving subagent contract safety, delegated-capability containment, plugin or hook ABI compatibility, session resumability, approval-flow correctness, and host-surface patch lifecycle integrity
- Add or update regression coverage for the new behavior
- If the task changes runtime behavior, trust boundaries, workflows, interop, or app/user-facing execution surfaces, add or update at least one scenario-level or end-to-end verification path
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `benchmarks/`
- `examples/`
- `docs/`
- `scripts/`

## Dependencies

- `CP-029`
- `CP-030`
- `CP-031`
- `CP-032`
- `AI-016`
- `AI-017`

## Acceptance

- `BM-041` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
