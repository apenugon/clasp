# Task: Repair The Handwritten Secret Surfaces Without Leaking Or Widening Access

This repository models one narrow handwritten baseline around declared secret handling.

The current implementation is too incomplete for the mirrored secret-handling scenario. Fix the local JavaScript surface so the benchmark proves all of the following at once:

- prompt and trace redaction keep secret values out of prompt payloads, traces, and prepared tool calls
- secret access stays policy-gated by the declared consuming boundary
- missing or misused declared secrets report the expected root-cause blame strings

## Working Guidance

- This task is intentionally local to the workspace.
- Start with `test/secret-handling.test.mjs` and `src/main.mjs`.
- Keep the solution explicit and readable. The intended fix is in the handwritten source, not in the test.

## Requirements

- Keep the reply worker, prompt, and tool wiring intact.
- Preserve the existing guide text, approval policy, and sandbox policy.
- The reply worker must only declare `OPENAI_API_KEY`.
- The search tool boundary must declare `SEARCH_API_TOKEN`.
- The demo must continue proving that prompt payloads, traces, and prepared tool calls do not contain resolved secret values.
- Return the same blame strings as the mirrored Clasp task:
  - `Missing secret SEARCH_API_TOKEN for toolServer SearchTools under policy SearchPolicy`
  - `Undeclared secret OPENAI_API_KEY for tool summarizeDraft`

## Constraints

- Keep the codebase small and readable.
- Do not patch the test to bypass missing declarations.

## Acceptance

The task is complete when `node test/secret-handling.test.mjs` passes.
