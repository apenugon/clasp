# TY-009 Add Package-Aware Module Resolution And Stable Module Identity Beyond The Current Flattened File-Path Model

## Goal

Add package-aware module resolution and stable module identity beyond the current flattened file-path model

## Why

Agents should not have to treat file paths as the primary semantic namespace of a codebase. `Clasp` needs stable module identity so declarations survive routine file moves, package reshapes, and refactors without losing graph addressability. This task belongs to the Type System And Diagnostics track.

## Scope

- Implement `TY-009` as one narrow slice of work: Add package-aware module resolution and stable module identity beyond the current flattened file-path model
- Keep the first slice focused on semantic identity and resolution rules rather than on package publishing or registry work.
- Add or update regression coverage for one preserved import path across a file move or equivalent identity-preserving change.
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/Clasp/Core.hs`
- `src/Clasp/Checker.hs`
- `src/Clasp/Diagnostic.hs`
- `src/Clasp/Lower.hs`
- `test/Main.hs`
- `docs/clasp-spec-v0.md`

## Dependencies

- `TY-008`

## Acceptance

- `TY-009` is implemented without breaking previously integrated tasks
- Declarations and modules have a compiler-known identity that is not reducible to the current raw file path alone.
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
