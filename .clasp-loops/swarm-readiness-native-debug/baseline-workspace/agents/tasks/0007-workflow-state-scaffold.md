# 0007 Workflow State Scaffold

## Goal

Introduce the first explicit workflow state scaffold for long-running programs.

## Scope

- Add a small syntax/design slice for workflow state declarations or annotations
- Typecheck the declared state shape
- Thread enough IR/runtime information to preserve it for future checkpoint/resume work
- Add tests and spec updates

## Acceptance

- `bash scripts/verify-all.sh` passes

## Notes

Keep this as a scaffold, not a full durable workflow engine in one task.
