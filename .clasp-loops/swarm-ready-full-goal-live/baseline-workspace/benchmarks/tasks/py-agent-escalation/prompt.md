# Task: Add Escalation to the Python Agent Decision Boundary

The repository models a small Python boundary around structured agent output.

Extend it to support an explicit escalation path.

## Requirements

- Add an `escalate` action to the shared decision model.
- Escalation decisions must include a non-empty `reason` string.
- `parse_agent_decision` should still reject invalid payloads at runtime.
- Validation failures should be informative enough to explain which fields were invalid.
- `should_escalate` should return `true` for escalation decisions.

## Constraints

- Keep the validation logic explicit and readable.
- Preserve the existing shared boundary structure.
- Do not replace validation with unchecked casts.

## Acceptance

The task is complete when `python3 -m unittest discover -s test -p '*_test.py'` passes.
