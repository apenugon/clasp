# Task: Deliver The Legal-Assistant AppBench Slice As A Clasp Checkpoint

The workspace models a bounded legal-assistant application for AppBench. The slice already has Clasp-native routes and typed runtime boundaries for:

- authenticated upload and replacement of legal documents
- durable document and conversation state
- explicit `@document[...]` references in chat prompts
- retrieval plus web-search tool orchestration
- citation-bearing answer payloads

Finish the slice so it behaves like a stable benchmark checkpoint rather than a demo script.

## Working Guidance

- This task is intentionally local to this workspace.
- Start with `Main.clasp`, `Process.clasp`, and `scripts/verify.sh`.
- Keep the accepted change on the app surface; only touch benchmark wiring if verification proves the harness is wrong.
- Preserve the typed records and ordinary-program execution path.

## Requirements

- Keep authenticated upload, replacement, and query handling working through ordinary `claspc run`.
- Persist document and conversation state durably across commands.
- Keep `@document[...]` references as high-priority retrieval context.
- Use both retrieval and web search when answering the benchmark query.
- Return cited document and web-search references in the answer payload.
- Keep the solution bounded and readable.

## Constraints

- Do not replace the Clasp program with shell-only orchestration.
- Do not remove durable state or citation fields to simplify the slice.
- Do not edit generated artifacts directly.

## Acceptance

The task is complete when `bash scripts/verify.sh` passes.
