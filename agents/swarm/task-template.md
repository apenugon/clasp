# SW-000 Short task title

## Goal

State the single behavior change this task should deliver.

## Why

Explain why this slice matters now and which track or milestone it supports.

## Scope

- Implement one narrow change set
- Add or update regression coverage
- Add a scenario-level or end-to-end verification path when the task changes a runtime, workflow, trust boundary, interop edge, or app-facing flow
- Avoid unrelated refactors

## Likely Files

- `path/to/file`

## Dependencies

- None

## Acceptance

- The target behavior is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```

<!--
Machine-readable manifest notes:
- schemaVersion is projected as 1 by the validator
- taskId is the markdown basename without .md
- taskKey is the leading SW-000 style identifier from the basename and H1
- title is the H1 text after the taskKey
- The parsed manifest is validated against agents/swarm/task.schema.json
-->
