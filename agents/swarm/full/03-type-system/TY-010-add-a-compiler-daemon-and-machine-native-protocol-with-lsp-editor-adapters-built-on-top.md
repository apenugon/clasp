# TY-010 Add A Compiler Daemon And Machine-Native Protocol, With LSP/Editor Adapters Built On Top

## Goal

Add a compiler daemon and machine-native protocol, with LSP/editor adapters built on top

## Why

Agents need a stable compiler-facing protocol for check, compile, graph query, projection, and edit operations. Human-facing CLI and editor integrations should be adapters over that protocol, not the only durable interface. This task belongs to the Type System And Diagnostics track.

## Scope

- Implement `TY-010` as one narrow slice of work: Add a compiler daemon and machine-native protocol, with LSP/editor adapters built on top
- Keep the first slice small and benchmark-oriented: one long-lived compiler process and one machine-readable request/response path are enough.
- Treat the protocol as the source of truth and the editor/LSP surface as a projection.
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

- `TY-009`

## Acceptance

- `TY-010` is implemented without breaking previously integrated tasks
- At least one compiler capability is available over a stable machine-readable protocol without shelling out to text-oriented CLI parsing.
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
