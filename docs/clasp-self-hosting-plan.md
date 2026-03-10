# Clasp Self-Hosting Plan

## Goal

Move `Clasp` from a Haskell-bootstrapped compiler to a compiler primarily implemented in `Clasp`, first through the `JS/Bun` path and later through a native backend.

The important distinction is:

- `hosted self-hosting`: the compiler is written in `Clasp` but still runs on the JavaScript runtime
- `native self-hosting`: the compiler is written in `Clasp` and runs through a native backend without Bun

The project should target hosted self-hosting first.

## When Clasp Should Be Self-Hosted

`Clasp` should not pursue self-hosting while the core language is still unstable.

The migration becomes worthwhile once these conditions hold:

- modules and package-aware resolution are stable enough for compiler code
- ADTs, records, pattern matching, lists, and local control flow are comfortable enough to express compiler passes
- `Option`, `Result`, and enough genericity exist for ordinary compiler data structures
- file, path, JSON, text, and CLI support exist in the runtime
- tests and bootstrap checks are strong enough to catch semantic drift

In roadmap terms, this means:

- experimentation can begin after the trust-boundary and app layers are credible
- the serious self-hosting push should happen after the first moderate SaaS app exists

## Prerequisites

Before a serious self-hosting push, the repo should already have:

- a stable typed core and lowered IR
- package-aware module resolution
- a formatter and explain-mode path
- regression-heavy parser/checker/emitter tests
- deterministic build outputs where practical
- enough standard-library support for text processing, collections, filesystem access, JSON, and CLI behavior

## Migration Order

### Stage 1: Compiler-Support Library

Build the `Clasp` standard-library surface needed by compiler code:

- text builders and parsing helpers
- collections used by the compiler
- file and path utilities
- structured diagnostics and rendering helpers
- test helpers for golden files and round-trip checks

### Stage 2: Low-Risk Compiler Components

Port the components that are easiest to isolate first:

- diagnostic rendering
- formatter / explain-mode renderer
- package and module loading helpers
- benchmark and manifest projection helpers

This phase reduces risk before the typechecker and parser move.

### Stage 3: Front End

Port the compiler front end in slices:

- lexer/parser
- AST and parser tests
- name resolution
- lowered IR helpers

Keep the Haskell compiler authoritative while these slices are brought across.

### Stage 4: Static Semantics and Emitters

Port the deeper compiler logic:

- checker and type inference
- schema derivation support
- JavaScript emitter
- route/runtime metadata emission

At this point, the Haskell compiler should be able to compile a mostly-`Clasp` compiler to JavaScript.

### Stage 5: Hosted Self-Hosting

Use the Haskell bootstrap compiler to build the `Clasp` compiler written in `Clasp`.

Run that compiler on `Bun`, then add bootstrap checks:

- stage0 Haskell compiler builds stage1 Clasp compiler
- stage1 Clasp compiler builds stage2 Clasp compiler
- stage1 and stage2 are identical or semantically equivalent

Once those checks are reliable, the `Clasp` implementation becomes the primary compiler, and Haskell remains the bootstrap fallback.

### Stage 6: Native Self-Hosting

Only after the hosted path is reliable should the project move to native self-hosting:

- define the native backend IR and ABI
- emit native bytecode or native-target IR
- add the native runtime needed by the compiler itself
- build and run the compiler through the native path

This is the point where `Clasp` truly stands on its own runtime feet.

## Definition Of Done

Hosted self-hosting is complete when:

- the primary compiler implementation is written in `Clasp`
- `Clasp` can compile itself through the JS/Bun path
- bootstrap reproducibility checks pass
- the Haskell compiler is needed only as a bootstrap path or fallback

Native self-hosting is complete when:

- the self-hosted compiler can run through the native backend
- backend/compiler benchmarks exist for both the JS and native paths
- the compiler no longer depends on Bun to run on server-side targets

## Non-Goals For The First Self-Hosting Push

The first self-hosting push should not also try to solve:

- full mobile-native runtime support
- SQLite or general-purpose persistence
- every advanced AI/provider feature
- every external-objective adaptation feature

Those can continue in parallel, but they should not block the hosted self-hosting milestone.
