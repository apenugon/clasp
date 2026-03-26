# 0005 Diagnostic Fix Hints

## Goal

Upgrade structured diagnostics with machine-consumable fix hints.

## Scope

- Extend the diagnostic model with optional fix metadata
- Add at least a few concrete fix hints for common current errors
- Preserve JSON-first diagnostics and pretty rendering
- Add tests that pin the JSON shape

## Acceptance

- `bash scripts/verify-all.sh` passes

## Notes

Prefer stable machine-readable fields over prose.
