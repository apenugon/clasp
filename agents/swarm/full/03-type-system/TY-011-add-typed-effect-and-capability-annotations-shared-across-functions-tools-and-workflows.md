# TY-011 Add Typed Effect And Capability Annotations Shared Across Functions, Tools, And Workflows

## Goal

Add typed effect and capability annotations shared across functions, tools, and workflows.

## Why

Clasp needs one coherent static model for authority-bearing behavior if it is going to become the default system language for software-building agents. This task belongs to the Type System And Diagnostics track.

## Scope

- Implement `TY-011` as one narrow slice of work: add typed effect and capability annotations shared across functions, tools, and workflows.
- Keep the first slice small and semantic: syntax, checking, and machine-readable representation are in scope; a complete runtime enforcement story is not.
- Ensure the annotations can be reused later by workflow, tool, and policy features instead of inventing separate capability models per subsystem.
- Add or update regression coverage for parsing, checking, and diagnostic behavior.
- Update docs or examples only where the new surface changes visible behavior.
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/Clasp/Syntax.hs`
- `src/Clasp/Parser.hs`
- `src/Clasp/Checker.hs`
- `src/Clasp/Core.hs`
- `src/Clasp/Diagnostic.hs`
- `test/Main.hs`
- `docs/clasp-spec-v0.md`
- `docs/ai-native-universal-language.md`

## Dependencies

- `TY-003`

## Acceptance

- One typed annotation model exists for authority-bearing behavior across ordinary functions, tools, and workflows.
- The checker rejects inconsistent or ill-formed effect and capability annotations with structured diagnostics.
- Machine-readable compiler output preserves the annotations for later control-plane and workflow phases.
- Tests or regressions cover the new behavior.
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
