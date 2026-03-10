# TASK-ID Task Title

## Goal

State the single behavior change this task should land.

## Why

Explain why this slice matters now.

## Scope

- Keep the task narrow.
- List only the changes this task should make.

## Likely Files

- `path/to/file`

## Batch

<!-- Optional batch label for a set of tasks that may run in parallel before downstream work begins. -->

## Dependency Labels

<!-- Optional batch labels that must be fully complete before this task starts. -->

## Dependencies

<!-- List upstream task IDs as bullet items. Leave this section empty when there are no dependencies. -->

## Acceptance

- Describe the observable outcome.
- Keep acceptance focused on this task only.

## Verification

```sh
bash scripts/verify-all.sh
```

## Machine-Readable Manifest

```json
{
  "id": "TASK-ID",
  "title": "Task Title",
  "goal": "State the single behavior change this task should land.",
  "why": "Explain why this slice matters now.",
  "scope": [
    "Keep the task narrow.",
    "List only the changes this task should make."
  ],
  "likely_files": [
    "path/to/file"
  ],
  "batch": null,
  "dependency_labels": [],
  "dependencies": [],
  "acceptance": [
    "Describe the observable outcome."
  ],
  "verification": "bash scripts/verify-all.sh"
}
```
