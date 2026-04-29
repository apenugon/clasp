# 0013 Edited Module Cold Check Speed

## Goal

Make `claspc --json check src/Main.clasp` stay practical after editing a large self-hosted compiler module.

The promoted module-summary seed already makes unchanged promoted sources fast on a fresh cache. This task targets the remaining case: a real edit invalidates one or more large module summaries and the checker falls back to expensive semantic work.

## Scope

- Focus on true cold semantic checking after edits to large self-hosted modules.
- Target modules first:
  - `src/Compiler/Ast.clasp`
  - `src/Compiler/Checker.clasp`
  - `src/Compiler/Emit/JavaScript.clasp`
  - `src/Compiler/Project.clasp`
  - `src/Compiler/SemanticArtifacts.clasp`
- Prefer structural wins over micro-optimizations.

## Required Work

- Measure a baseline by making a reversible body-only edit to at least one large compiler module and timing:
  `claspc --json check src/Main.clasp`
- Improve the edited-module path without weakening typechecking correctness.
- Measure the same edited-module scenario after the change.
- Add or update a focused gate so this path does not regress silently.
- Keep the promoted module-summary seed and its existing checks intact.

## Constraints

- Do not claim success from unchanged-source promoted-cache hits.
- Do not remove or bypass semantic checking for edited modules unless the replacement is correctness-preserving.
- Do not broaden into new swarm features.
- Keep changes scoped enough that `bash scripts/verify-all.sh` remains realistic for the verifier.

## Acceptance

- There is at least one measured before/after win for a real edited large compiler module.
- `claspc --json check src/Main.clasp` no longer falls back to minute-scale or timeout behavior for the measured edited-module case.
- A permanent or focused regression gate covers the improved path.
- `bash scripts/verify-all.sh` passes in the verifier stage.

## Notes

- Likely directions include interface/body split caching, checker fast paths for fully annotated declarations, narrower invalidation boundaries, and avoiding duplicate body inference.
- If the best achievable result is warm-cache only, state that explicitly and leave a precise next step.
