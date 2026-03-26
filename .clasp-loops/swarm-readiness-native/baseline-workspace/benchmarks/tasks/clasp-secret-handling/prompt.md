# Task: Repair the Clasp Secret Surfaces Without Leaking Or Widening Access

This repository models one narrow `Clasp` benchmark around declared secret handling.

The current declarations are too incomplete for the mirrored secret-handling scenario. Fix the local `Clasp` surface so the benchmark proves all of the following at once:

- prompt and trace redaction keep secret values out of prompt payloads, traces, and prepared tool calls
- secret access stays policy-gated by the declared consuming boundary
- missing or misused declared secrets report the expected root-cause blame strings

## Working Guidance

- This task is intentionally local to the workspace.
- Start with `test/secret-handling.test.mjs` and `Main.clasp`.
- Keep the fix declarative. The intended change is in the `Clasp` declarations, not in the JavaScript demo or test.

## Requirements

- Keep the reply worker, prompt, and tool wiring intact.
- Preserve the existing guide text, approval policy, and sandbox policy.
- The reply worker must only declare `OPENAI_API_KEY`.
- The search tool boundary must declare `SEARCH_API_TOKEN`.
- The demo must continue proving that prompt payloads, traces, and prepared tool calls do not contain resolved secret values.
- The demo must continue proving the exact missing-secret blame string:
  `Missing secret SEARCH_API_TOKEN for toolServer SearchTools under policy SearchPolicy`
- The demo must continue proving the exact misused-secret blame string:
  `Undeclared secret OPENAI_API_KEY for tool summarizeDraft`

## Constraints

- Keep the codebase small and readable.
- Do not patch the JavaScript demo or test to bypass missing declarations.

## Acceptance

The task is complete when `bash scripts/verify.sh` passes.
