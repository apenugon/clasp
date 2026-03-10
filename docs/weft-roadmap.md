# Weft Roadmap

## Principle

Build `Weft` in layers:

1. Language core
2. Universal app platform
3. AI/agent platform

And evaluate it continuously against agent-harness benchmarks so language design is tied to real task performance rather than speculation.

The mistake to avoid is shipping a speculative vision instead of a working compiler.

## Phase 0: Foundation

- Finalize the language name and design direction
- Write the long-term design note
- Write the concrete v0 spec
- Define the initial compiler architecture
- Keep the bootstrap syntax explicitly provisional rather than accidental language law

Exit criteria:

- The project has stable positioning and first implementation boundaries.

## Phase 1: Tooling Bootstrap

- Add a Nix flake for reproducible development
- Create a Cabal package
- Establish the initial repository layout
- Ensure the project builds on a clean machine via `nix develop`

Exit criteria:

- A contributor can enter the dev environment and build the compiler.

## Phase 2: Front-End Scaffold

- Implement the parser
- Define the syntax tree
- Add useful parse errors
- Add a `parse` CLI command
- Preserve room to shrink or remove low-value syntax like file-level boilerplate in later phases

Exit criteria:

- The compiler parses valid `Weft` source and prints the AST.

## Phase 3: First Code Generation

- Implement a JavaScript emitter
- Add a `compile` CLI command
- Create sample source files
- Verify the emitted JavaScript executes under a normal JS runtime

Exit criteria:

- A small `Weft` module compiles to JavaScript and runs.

## Phase 4: Static Semantics

- Add name resolution
- Add a minimal typechecker
- Add boundary annotations where needed
- Start shaping the type system toward ADTs and exhaustive matching
- Build structured, high-signal compiler diagnostics instead of raw parser/type errors
- Treat machine-readable diagnostics as the primary interface and human-oriented rendering as a derived view

Exit criteria:

- The compiler catches basic undefined names and interface mismatches before codegen.

## Phase 5: Full-Stack Core

- Add schemas as a language-level construct
- Add typed serialization and validation derivation
- Add typed route/service definitions
- Start converging on one shared type universe for frontend/backend boundaries

Exit criteria:

- A single `Weft` codebase can define shared app types and compile them across layers.

## Phase 6: Trust Boundaries

- Generate validators, encoders, and decoders from schemas
- Auto-run generated validation at runtime trust boundaries
- Model LLM outputs and tool results as typed but untrusted inputs
- Start designing versioned state handoff for future hot swapping

Exit criteria:

- Untrusted values become typed `Weft` values only through generated validation.

## Phase 7: Durable Workflows

- Add workflow state modeling
- Add typed checkpoint/resume support
- Add idempotency and replay concepts
- Add explicit side-effect capabilities
- Add supervised module hot-swap and self-update semantics

Exit criteria:

- Long-running programs remain type-safe and replayable across restarts.

## Phase 8: AI-Native Platform

- Add model/provider interfaces
- Add structured output handling
- Add tool declarations
- Add tracing and eval hooks

Exit criteria:

- `Weft` can express a typed AI workflow without falling back to ad hoc SDK glue.

## Phase 9: Mobile and Runtime Expansion

- Keep JavaScript as the first practical shared runtime
- Add stronger support for app runtimes
- Decide whether native targets are warranted after the core language stabilizes
- Preserve a compiler architecture that can support a future LLVM-oriented backend without rewriting the front end

Exit criteria:

- Shared application logic is practical across web, backend, and app environments.

## Long-Term Backend Direction

`Weft` should treat JavaScript as the first target, not the only target.

The desired architecture is:

- one front end
- one type system
- one typed core
- one lowered IR
- multiple emitters

That makes a split strategy feasible later:

- JavaScript for browser and app-adjacent runtimes
- a native or LLVM-oriented backend for server workloads where that becomes worthwhile

The project should not commit to native codegen too early, but it should keep the path open deliberately.

## Long-Term Surface Syntax Direction

`Weft` should move toward a compact canonical source form rather than inheriting human-first verbosity from early prototypes.

That means:

- stripping boilerplate that can be inferred
- reducing mandatory keywords that add little semantic value
- preferring one compact canonical form over multiple equivalent styles
- providing human-readable explain and pretty-print modes as renderings over the canonical form

The project should benchmark syntax candidates with real agent harnesses before freezing the surface language.


## Immediate Working Track

The current implementation should focus on:

- Getting the bootstrap environment right
- Building a small clean compiler around the typed core and lowered IR
- Keeping the language surface intentionally tiny while expanding toward real app-building primitives
- Using generated codecs, foreign bindings, and typed routes as the base for the first benchmarkable full-stack slice
- Avoiding premature complexity in effects or AI syntax before schemas, trust boundaries, and hot-swap semantics land

## Cross-Cutting Benchmark Track

Benchmarking should begin early and continue across all phases.

Near-term benchmark work should include:

- defining a benchmark harness around `Codex` and `Claude Code`
- creating a baseline task suite in `TypeScript`
- measuring intervention-free completion, total tokens, repair loops, and time-to-green
- expanding later into trust-boundary, workflow, and LLM-output benchmarks
- testing compact-syntax candidates against more verbose alternatives before committing to a final Weft surface

Benchmark results should influence language and platform prioritization throughout the project.
