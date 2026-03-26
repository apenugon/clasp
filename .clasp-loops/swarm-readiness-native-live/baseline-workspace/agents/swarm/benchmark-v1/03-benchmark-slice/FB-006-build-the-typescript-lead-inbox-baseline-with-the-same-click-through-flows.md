# FB-006 Build The TypeScript Lead-Inbox Baseline With The Same Click-Through Flows

## Goal

Build the canonical `TypeScript` lead-inbox baseline with the same click-through flows.

## Why

The benchmark is only credible if both language variants expose the same human-runnable product flow rather than comparing a real app against an API toy. But the benchmark should still measure agents changing intentionally incomplete starting repos, not the swarm delivering a fully solved final comparison app. This task should therefore build the canonical `TypeScript` baseline that later benchmark task repos are derived from.

## Scope

- Add or update the mirrored `TypeScript` lead-inbox baseline so it matches the benchmark slice defined for `Clasp`.
- Keep the baseline honest and modest: server-rendered pages, in-memory state, one AI-shaped boundary, and the same product flow are enough.
- Align test coverage and verification style closely with the `Clasp` version without forcing identical implementation details.
- Make the result suitable as the canonical mirrored baseline from which intentionally incomplete benchmark task repos can be derived.
- Do not treat this task as pre-solving the later benchmark prompts; leave prompt-specific changes to `FB-007` task packaging.
- Avoid over-engineering the baseline with extra framework features the `Clasp` slice does not depend on.

## Likely Files

- `benchmarks/`
- `examples/`
- `test/`

## Dependencies

- `FB-004`
- `FB-005`

## Acceptance

- The mirrored `TypeScript` canonical baseline exposes the same click-through lead-inbox flow as the `Clasp` baseline.
- A human can boot the baseline locally and click through the core flow in a browser.
- The task output is explicitly usable as the starting point for intentionally incomplete benchmark task repos.
- Tests or regressions cover the aligned flow and at least one invalid input or invalid-boundary path.
- `bash scripts/verify-all.sh` passes.

## Verification

```sh
bash scripts/verify-all.sh
```
