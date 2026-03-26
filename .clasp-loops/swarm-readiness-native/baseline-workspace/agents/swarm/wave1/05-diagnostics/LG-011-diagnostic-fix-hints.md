# LG-011 Diagnostic Fix Hints

## Goal

Add fix-hint metadata to the current structured diagnostics.

## Why

Diagnostics are a primary agent interface in Clasp. They should carry actionable machine-readable hints, not just summaries and spans.

## Scope

- Extend the diagnostic model with fix-hint metadata
- Populate fix hints for at least a few existing error families
- Update JSON rendering and any pretty rendering as needed
- Add regression coverage

## Likely Files

- `src/Clasp/Diagnostic.hs`
- `src/Clasp/Checker.hs`
- `src/Clasp/Parser.hs`
- `test/Main.hs`
- `docs/clasp-spec-v0.md`

## Dependencies

- None

## Acceptance

- Diagnostic JSON includes fix-hint data
- At least a few existing errors expose useful hints
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
