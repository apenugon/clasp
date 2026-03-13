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
- file, path, text, schema-projection, and machine-protocol support exist in the runtime
- tests and bootstrap checks are strong enough to catch semantic drift

In roadmap terms, this means:

- experimentation can begin after the trust-boundary and app layers are credible
- the serious self-hosting push should happen after the first moderate SaaS app exists

## Prerequisites

Before a serious self-hosting push, the repo should already have:

- a stable typed core and lowered IR
- package-aware module resolution with stable module identity
- a formatter and explain-mode path
- a machine-native compiler protocol that can serve checking, graph queries, and projections
- regression-heavy parser/checker/emitter tests
- deterministic build outputs where practical
- enough standard-library support for text processing, collections, filesystem access, schema projections, and protocol-serving behavior

## Self-Hosting Subset

The first self-hosted compiler should target a deliberately narrow subset of `Clasp`.

That subset is the part of the language needed to express compiler passes and compiler-support libraries without depending on app-facing runtime features.

The initial self-hosting subset includes:

- package-aware modules and imports
- top-level value and function declarations
- local `let`, block expressions, and ordinary control flow
- `Int`, `Float`, `Bool`, `Str`, `List`, records, ADTs, and pattern matching
- `Option`, `Result`, and generic data structures needed for compiler state
- JSON, schema, and protocol projection support used to exchange compiler-owned artifacts
- filesystem, path, and text helpers required by compiler loading, diagnostics, and emitters

The initial self-hosting subset explicitly does not require compiler code itself to depend on:

- page/view declarations
- route handlers as the way compiler passes are composed internally
- workflow, worker, or durable execution features
- agent, policy, hook, tool-server, or secret-management declarations
- foreign-package interop as a required way to implement core compiler passes
- native-backend-only capabilities

Those surfaces still need to be compiled correctly for user programs, but they are outside the minimum language/runtime surface the compiler implementation may rely on before hosted self-hosting is established.

## Bootstrap And Primary Compiler Boundary

The bootstrap compiler and the primary compiler should have different responsibilities during the hosted self-hosting transition.

The bootstrap compiler implementation in Haskell is responsible for:

- remaining the release-producing and fallback compiler until stage0/stage1/stage2 checks pass
- supporting the self-hosting subset before the `Clasp` compiler is allowed to depend on it
- serving as the semantic reference when the hosted compiler disagrees with expected output
- compiling the `Clasp` compiler to the first runnable JS/Bun artifact

The primary compiler implementation in `Clasp` is responsible for:

- owning all newly ported compiler passes once their stage checks are stable
- staying within the self-hosting subset until `SH-010` promotes it to the default compiler path
- producing the same typed core, lowered IR, diagnostics, and emitted JavaScript expected from the bootstrap path
- becoming the default implementation only after reproducibility and compatibility checks are reliable

The practical boundary is:

- new compiler logic should land in `Clasp` once the needed subset features and library support exist
- new language features for end users still land in the Haskell compiler first if the `Clasp` compiler cannot yet compile or exercise them
- the Haskell compiler remains the compatibility oracle and bootstrap path, not the place for ongoing duplicate feature work, once a pass has moved across successfully

A language or runtime feature enters the self-hosting subset only when:

- the Haskell bootstrap compiler already supports it
- the runtime or standard-library contract it needs is stable enough for compiler code
- regression coverage exists for both direct behavior and stage/compatibility behavior
- depending on that feature reduces overall bootstrap debt instead of increasing it

## Migration Order

### Stage 1: Compiler-Support Library

Build the `Clasp` standard-library surface needed by compiler code:

- text builders and parsing helpers
- collections used by the compiler
- file and path utilities
- protocol and semantic-query helpers
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
