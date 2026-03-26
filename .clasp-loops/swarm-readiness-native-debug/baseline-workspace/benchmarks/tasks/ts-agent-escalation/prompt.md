# Task: Add Escalation to the Agent Decision Boundary

The repository models a small typed boundary around structured agent output.

Extend it to support an explicit escalation path.

## Requirements

- Add an `escalate` action to the shared decision model.
- Escalation decisions must include a non-empty `reason` string.
- `parseAgentDecision` should still reject invalid payloads at runtime.
- Validation failures should be informative enough to explain which fields were invalid.
- `shouldEscalate` should return `true` for escalation decisions.

## Constraints

- Keep the validation logic explicit and readable.
- Preserve the existing typed/shared boundary structure.
- Do not replace validation with unchecked casts.

## Acceptance

The task is complete when `npm test` passes.

