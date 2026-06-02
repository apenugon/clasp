# 0008 LLM Provider Interface Scaffold

## Goal

Add the first provider-agnostic model boundary scaffold.

## Scope

- Introduce a minimal language/runtime surface for typed model calls
- Keep model output explicitly untrusted until validated
- Reuse the current generated validation machinery where possible
- Add tests and documentation

## Acceptance

- `bash scripts/verify-all.sh` passes

## Notes

This is a scaffold task. The target is a narrow, typed boundary rather than a complete agent framework.

## Current Slice

- `examples/swarm-native/ModelBoundary.clasp` defines the first provider-neutral request/untrusted-output/validated-output shape for planner model calls.
- `validatePlannerModelOutput` keeps raw provider text untrusted until provider/model/schema/status checks, `tryDecode PlannerReport`, required-field guards, and planner-shape checks succeed.
- `scripts/test-model-boundary.sh` verifies the boundary through both generated JavaScript and native execution.
