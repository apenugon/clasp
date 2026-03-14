# Task: Restore Compiler-Managed Python Interop In Clasp

This benchmark compares compiler-managed Python worker and service boundaries against handwritten host glue on the same task.

## Working Guidance

- This task is intentionally local to this workspace.
- Start with `Main.clasp`, then read `demo.mjs` and `scripts/verify.sh`.
- Keep the solution declarative. The intended fix is in the typed hook and route declarations, not in the Python files.

## Requirements

- The compiler-managed Python runtime must expose one worker boundary named `workerStart`.
- The compiler-managed Python runtime must expose one service boundary named `summarizeRoute`.
- The demo must print this exact JSON:
  `{"workerRunning":true,"workerAccepted":true,"workerLabel":"py:worker-7","workerStopped":false,"workerRestarted":true,"serviceSummary":"py:Acme:42","serviceAccepted":true,"serviceStopped":false,"invalid":"budget must be an integer"}`
- Do not replace the typed Clasp surface with handwritten JavaScript process glue.

## Acceptance

The task is complete when `bash scripts/verify.sh` passes.
