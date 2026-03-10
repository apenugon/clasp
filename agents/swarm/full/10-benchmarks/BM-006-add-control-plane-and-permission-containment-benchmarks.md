# BM-006 Add Control-Plane And Permission-Containment Benchmarks

## Goal

Add control-plane and permission-containment benchmarks.

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Add one benchmark pair for control-plane and permission containment: one `Clasp` task and one baseline task.
- Use a narrow scenario with one allowed action and one denied or gated action under declared policy.
- Add checked-in task fixtures under `benchmarks/tasks/` with prompts, manifests, repo fixtures, and verify scripts.
- Keep this slice focused on permission containment and control-plane leverage. Do not expand the benchmark harness beyond the fields needed to record this scenario.
- Add or update regression coverage for task discovery and benchmark result recording if the new task shape requires it.
- Update docs or examples only where the new surface changes visible behavior.
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `benchmarks/tasks/`
- `benchmarks/run-benchmark.mjs`
- `benchmarks/result-schema.json`
- `benchmarks/README.md`

## Dependencies

- `CP-009`

Assume `CP-009` has already landed real permission enforcement for file, network, process, or secret capabilities.

## Acceptance

- A benchmark pair exists for one `Clasp` scenario and one baseline-language scenario.
- Each scenario includes a task manifest, prompt, repo fixture, and verify script.
- The verify path proves one allowed action succeeds and one denied or gated action is contained.
- The benchmark runner can record results for the new scenarios without breaking existing output shape.
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
