# FS-012 Add A Compiler-Known Style IR With Target Lowering And Explicit Host-Style Escape Hatches

## Goal

Add a compiler-known style IR with target lowering and explicit host-style escape hatches.

## Why

If `Clasp` wants the compiler to reason about UI placement, refactors, extraction, and cross-target rendering, styling cannot remain only free-form `class` or raw `style` strings. This task belongs to the Full-Stack Runtime And App Layer track.

## Scope

- Implement `FS-012` as one narrow slice of work: add a compiler-known style representation that can express a small set of design tokens, composition, and target-aware variants.
- Make the default style path typed and compiler-owned rather than treating raw host class/style strings as ordinary attrs.
- Support explicit raw host-style escape hatches for interop, clearly marked as host-specific or unsafe.
- Lower the first target to web output in a deterministic way that leaves room for later native or cross-platform renderers.
- Add or update regression coverage for style construction, lowering, and raw host-style escapes.
- Update docs or examples only where the new surface changes visible behavior.
- Avoid turning this task into a full design system, CSS framework clone, or large frontend runtime.

## Likely Files

- `src/Clasp/Syntax.hs`
- `src/Clasp/Parser.hs`
- `src/Clasp/Checker.hs`
- `src/Clasp/Core.hs`
- `src/Clasp/Lower.hs`
- `src/Clasp/Emit/JavaScript.hs`
- `runtime/`
- `examples/`
- `test/Main.hs`
- `docs/clasp-spec-v0.md`

## Dependencies

- `FS-004`

## Acceptance

- `Clasp` has a compiler-known style representation for the initial web target.
- The default page/view styling path does not require free-form raw class/style strings.
- Raw host class/style interop remains available only through explicit host-specific or unsafe escape hatches.
- Lowering and runtime output remain deterministic enough for agents, refactors, and future target expansion.
- Tests or regressions cover typed style composition, target lowering, and raw host-style escape behavior.
- `bash scripts/verify-all.sh` passes.

## Verification

```sh
bash scripts/verify-all.sh
```
