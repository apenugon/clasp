# Clasp Roadmap

## Principle

Build `Clasp` in layers:

1. Language core
2. Universal app platform
3. AI/agent platform

And evaluate it continuously against agent-harness benchmarks so language design is tied to real task performance rather than speculation.

The mistake to avoid is shipping a speculative vision instead of a working compiler.

The proving ground that matters most is not a toy compiler demo. It is whether an agent can build and evolve a real moderate SaaS application faster in `Clasp` than in a baseline stack.

## First Credible Benchmark

The first public proof point should not be a toy compiler demo or a syntax-only microbenchmark.

It should be a moderate SaaS slice where:

- `Clasp` owns shared schemas, generated boundary validation, backend logic, generated clients, and one AI/tool boundary
- the agent must make coordinated product changes across multiple layers
- at least one host/runtime boundary remains in play so interoperability is being tested rather than assumed away
- the same scenarios run against a practical `TypeScript` baseline and, where useful, a `Python` orchestration baseline

This first credible benchmark should not wait for:

- full control-plane completeness
- durable hot-swap and self-update semantics
- self-hosting
- native backend work
- SQLite-backed persistence

Those later layers still matter, but they should build on top of an earlier product-level proof that `Clasp` improves agent throughput on realistic work.

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

- The compiler parses valid `Clasp` source and prints the AST.

## Phase 3: First Code Generation

- Implement a JavaScript emitter
- Add a `compile` CLI command
- Create sample source files
- Verify the emitted JavaScript executes under a normal JS runtime

Exit criteria:

- A small `Clasp` module compiles to JavaScript and runs.

## Phase 4: Static Semantics

- Add name resolution
- Add a minimal typechecker
- Add boundary annotations where needed
- Start stabilizing a compiler-known semantic IR that can later serve as an agent-facing AIR rather than leaving plans and tool flows as ad hoc runtime JSON
- Add stable package/module identity beyond the current file-path-oriented import story
- Start shaping the type system toward ADTs and exhaustive matching
- Add constrained or refinement-style value modeling for important application invariants
- Build structured, high-signal compiler diagnostics instead of raw parser/type errors
- Treat machine-readable diagnostics as the primary interface and human-oriented rendering as a derived view
- Add semantic edit and refactor operations over compiler-known declarations rather than relying only on raw text patching
- Make a machine-native compiler protocol the primary tooling surface, with CLI and editor adapters built on top
- Add a first-class proof and assumption ledger so the compiler can report what is statically proved, runtime-checked, foreign-trusted, unsafe-assumed, or still unresolved

Exit criteria:

- The compiler catches basic undefined names and interface mismatches before codegen.

## Phase 5: Full-Stack Core

- Add schemas as a language-level construct
- Add typed serialization, validation, and transport-projection derivation
- Add typed route/service definitions
- Start converging on one shared type universe for frontend/backend boundaries
- Add first-class auth/session, principal, tenant, and resource identity primitives rather than leaving app auth as optional middleware glue
- Add compiler-known authorization requirements and proof-carrying access surfaces for routes, pages, actions, queries, and tools
- Replace raw string route edges with structured route identity and typed path/query/body contracts
- Add compiler-known page/view semantics and reserve a compiler-known styling path rather than freezing raw class strings as language law
- Add typed actions, forms, redirects, and navigation contracts for page and app flows
- Emit UI/action graph artifacts so agents can reason over product flows semantically rather than only through browser scraping
- Add compiler-known state-transition or typestate surfaces where they prove benchmark value for app correctness
- Add typed asset/head/style bundle declarations so UI outputs remain part of one semantic model
- Formalize stable host interop contracts with structured capability identities so the first benchmark can reuse existing ecosystems without stringly binding drift
- Add compiler-managed foreign package imports so `npm` and `TypeScript` ecosystems can be consumed through typed manifests, declaration ingestion, and generated adapters instead of handwritten glue
- Add compiler-managed `Python` package and module interop as typed worker or service boundaries with generated schema bindings, transport, and lifecycle management
- Add compiler-managed `Rust` crate or native-library interop for performance-critical extensions, using generated bindings, capability metadata, and target-aware build integration
- Treat untyped or weakly typed foreign values as explicit boundary-only `Dynamic` or `Unknown` values rather than ambient `Any`
- Require explicit unsafe refinement when the compiler cannot prove a foreign declaration matches the claimed `Clasp` type
- Preserve blame-carrying boundary diagnostics so runtime type failures identify the exact foreign import, declaration, expected type, observed path, and unsafe assertion site

Exit criteria:

- A single `Clasp` codebase can define shared app types, UI structure, and style intent and compile them across layers.

## Phase 6: Trust Boundaries

- Generate validators, encoders, and decoders from schemas
- Auto-run generated validation at runtime trust boundaries
- Model LLM outputs and tool results as typed but untrusted inputs
- Use one schema universe for HTTP payloads, tool IO, workflow state, config, and model outputs
- Keep boundary schemas transport-neutral so `JSON` is a projection, not the permanent semantic model
- Add binary boundary projections for efficient service, worker, and agent-to-agent communication once the schema model is stable enough
- Add invariant, precondition, and postcondition declarations that can be checked statically where possible and enforced automatically at boundaries where necessary
- Add field-level data classification and disclosure rules so protected values cannot flow into pages, prompts, traces, or storage projections without explicit policy mediation
- Add provenance tracking and secret-aware value handling at trust boundaries
- Add compiler-known secret declarations and typed injection surfaces for environment and host secret providers
- Add non-loggable, non-serializable secret value semantics with explicit reveal or redaction boundaries instead of ambient string access
- Add delegated secret capabilities with compiler-known attenuation rules for audience, action, TTL, and bounded-use delegation
- Add typed audit event schemas and standard audit envelopes for boundary decisions, data disclosures, tool calls, and state changes
- Start separating untrusted content from authority-bearing instructions and capabilities
- Start designing versioned state handoff for future hot swapping

Exit criteria:

- Untrusted values become typed `Clasp` values only through generated validation.

## Phase 7: Operational Control Plane

- Add compiler-known declarations for repo memory, permissions, commands, hooks, agents, tool servers, verification, and traces
- Keep these declarations in the same module graph and type universe as application code
- Generate executable machine manifests, protocol artifacts, human-readable docs, CLI wrappers, and runtime config from the same source
- Emit a static context graph over code, control-plane declarations, schemas, and capabilities
- Enforce capability and approval policies from declared semantics instead of shell conventions
- Make policy decisions and authorization proofs traceable back to principal, resource, action, and data-classification declarations
- Add explicit sandbox and least-privilege policy surfaces for file, network, process, secret, and model authority
- Add secret-access audit trails and missing-secret diagnostics tied back to declared secret inputs, policies, and consuming boundaries
- Add auditability for secret delegation chains so secret use can be traced through delegation and attenuation rather than only direct access
- Add first-class audit log declarations, sink routing, retention rules, and redaction policy so auditability is compiler-owned instead of bolted onto host logging
- Make audit trails and policy decisions part of standard trace output
- Add compiler-known environment and deployment declarations for services, queues, schedules, regions, secrets, budgets, rollout targets, and topology constraints, then project them into host deploy artifacts instead of ambient config
- Add counterfactual impact preview queries so agents can ask what declarations, proofs, policies, migrations, rollouts, and runtime checks would change before editing

Exit criteria:

- A repository can declare its agent memory, permissions, tool interfaces, commands, hooks, and verifier rules in `Clasp` and have them enforced and projected from one source of truth.
- Static context-graph queries can resolve relevant declarations, policies, and capabilities without repository-wide text search.

## Phase 8: Durable Workflows

- Add workflow state modeling
- Add an Erlang/BEAM-inspired isolation model for long-running workflow processes
- Add typed checkpoint/resume support
- Add idempotency and replay concepts
- Add explicit side-effect capabilities
- Add typed workflow audit events for transitions, retries, operator handoffs, upgrades, and rollbacks
- Extend context-graph emission with runtime execution edges for workflow state transitions, failures, retries, and handoffs
- Add deadlines, cancellation, retry policy, and bounded backoff semantics
- Treat time as a first-class semantic dimension covering TTLs, expirations, schedules, rollout windows, cache staleness, and delegated-capability expiry
- Add degraded-mode and operator-handoff semantics for partial failure
- Add supervisor trees, restart strategies, and mailbox-style coordination where needed
- Add supervised module hot-swap and self-update semantics with dual-version upgrade windows and explicit state-upgrade handlers
- Add deterministic simulation and dry-run support for routes, workflows, agent loops, policy decisions, and temporal behavior using declared fixtures and simulated time

Exit criteria:

- Long-running programs remain type-safe and replayable across restarts.
- Hot upgrades follow supervised, BEAM-inspired handoff rules rather than arbitrary in-place mutation.

## Phase 9: AI-Native Platform

- Add model/provider interfaces
- Add typed prompt functions and structured output handling
- Add typed streaming and partial-result semantics
- Add provider strategies such as fallback, retry, round-robin, and budget policy
- Add tool declarations
- Add tracing and eval hooks
- Add a compiler-owned agent intermediate representation (`AIR`) that prompts, plans, tools, workflows, and source modules can all project into with stable identifiers and replayable serialization
- Extend context graphs with prompt, tool, model, eval, and capability edges suitable for prompt-building and inspector tooling
- Add a constrained dynamic-schema facility for runtime-selected output shapes
- Add prompt-injection-resistant separation between content, tool authority, and policy
- Add secret-redaction and provenance rules for prompts, traces, and tool calls
- Add secret-aware prompt and tool-input surfaces that consume declared secret handles rather than raw ambient strings
- Preserve clean interoperability with systems like `BAML` while making the core model native to `Clasp`
- Extend interoperability beyond AI-specific systems so higher-level `Clasp` programs can consume `npm`, `PyPI`, and `Cargo` ecosystems through compiler-managed foreign package surfaces rather than bespoke runtime glue

Exit criteria:

- `Clasp` can express a typed AI workflow without falling back to ad hoc SDK glue.
- Higher-level planners or natural-language compilers can target one stable `Clasp` AIR instead of inventing bespoke execution JSON for each runtime.

## Phase 10: External-Objective Adaptation

- Add first-class domain-object, event, metric, goal, experiment, and rollout concepts where they prove benchmark value
- Make runtime feedback traceable back to affected routes, prompts, workflows, policies, and tests
- Support typed ingestion of market, operational, safety, compliance, and other external feedback
- Extend context graphs with objective-layer nodes and edges for domain objects, metrics, goals, experiments, and rollouts
- Make eval and rollout gates expressible in terms of external outcomes rather than code-only correctness
- Add safe rollout, automatic rollback, and kill-switch semantics for bounded autonomous change

Exit criteria:

- An agent can move from typed external feedback to a bounded code and rollout change without reconstructing the domain model from scratch on every task.
- Objective-graph queries can connect external signals to affected declarations, policies, tests, evals, and rollout gates.

## Phase 11: Moderate SaaS Dogfooding

- Build one moderate SaaS application using only `Clasp` for application logic
- Keep the first version intentionally database-free so the language, compiler, generated clients, trust boundaries, and workflows are the thing being tested
- Use generated route clients, generated validation, compiler-owned page/view semantics, and compiler-owned styling semantics across the entire app surface
- Add benchmark tasks that ask `Codex`, `Claude Code`, and future harnesses to add and modify real product features in that app

Exit criteria:

- A moderate SaaS app runs with frontend, backend, workers, and agent features written in `Clasp`
- The app does not rely on TypeScript or Python for core product logic
- Benchmark tasks now include app-level feature work, not just schema and compiler slices

## Phase 12: Self-Hosted Compiler

- Define the self-hosting subset of `Clasp`
- Port the compiler gradually from Haskell to `Clasp`
- Keep the first self-hosted compiler path running on `JS/Bun`
- Add stage1 and stage2 bootstrap checks so the compiler can compile itself reproducibly

Exit criteria:

- The primary compiler implementation is written in `Clasp`
- The Haskell compiler remains available as a bootstrap fallback
- Bootstrap reproducibility checks pass for the self-hosted path

## Phase 13: Native Backend and Bytecode Emission

- Add a backend-oriented native IR beneath the lowered IR
- Define a runtime ABI and data layout for native execution
- Emit real backend-native bytecode or native-target IR instead of depending only on JavaScript for server workloads
- Support the same compiler-owned boundary projections on the native path, including later binary codecs where they matter for backend transport
- Run the self-hosted compiler and backend services through the native path

Exit criteria:

- `Clasp` can run backend/compiler workloads without Bun
- The native path shares the same front end and type system as the JS path
- Backend benchmarks can compare JS/Bun and native execution on the same language implementation

## Phase 14: Native Storage With SQLite First

- Add a language-native storage model with `SQLite` as the first backend
- Add a typed SQLite capability and connection model
- Add typed schema/query/transaction/migration surfaces
- Add policy-aware query and mutation surfaces so protected rows and fields require explicit authorization proofs instead of ambient data access
- Generate database constraints from `Clasp` schemas and invariants where possible
- Keep raw SQL behind explicit unsafe or foreign boundaries rather than as the default query surface
- Integrate persistence into the SaaS dogfood app
- Benchmark persistence-bearing app changes, not just stateless features

Exit criteria:

- `Clasp` can connect to SQLite through a typed storage boundary
- schema-derived query, transaction, migration, and constraint surfaces exist
- raw SQL exists only through explicit unsafe or foreign boundaries
- The SaaS dogfood app runs with real persistence
- The benchmark suite includes database-backed product changes

## Phase 15: Mobile and Runtime Expansion

- Keep JavaScript as the first practical shared runtime
- Add stronger support for app runtimes
- Decide whether native targets are warranted after the core language stabilizes
- Preserve a compiler architecture that can support a future LLVM-oriented backend without rewriting the front end

Exit criteria:

- Shared application logic is practical across web, backend, and app environments.

## Long-Term Backend Direction

`Clasp` should treat JavaScript as the first target, not the only target.

The desired architecture is:

- one front end
- one type system
- one typed core
- one lowered IR
- multiple emitters, including a native backend path

That makes a split strategy feasible later:

- JavaScript for browser and app-adjacent runtimes
- real backend-native bytecode or an LLVM-oriented backend for server workloads where that becomes worthwhile

The project should not commit to native codegen too early, but it should keep the path open deliberately.

## Long-Term Surface Syntax Direction

`Clasp` should move toward a compact canonical source form rather than inheriting human-first verbosity from early prototypes.

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
- Keeping `JSON` as the first debug-friendly boundary format while preserving a path to later binary projections for high-volume boundaries
- Moving toward machine-native compiler and platform protocols instead of treating CLI text and path conventions as the long-term primary interface
- Prioritizing the minimum path to a benchmark-ready moderate SaaS slice over speculative platform breadth
- Treating interoperability as part of the critical path, not an escape hatch
- Using the eventual moderate SaaS app as the primary design-pressure test for agent productivity
- Avoiding premature complexity in effects or AI syntax before schemas, trust boundaries, operational control-plane semantics, and hot-swap semantics land
- Not blocking the first credible benchmark on control-plane completeness, hot-swap, self-hosting, native backend work, or SQLite

## Cross-Cutting Benchmark Track

Benchmarking should begin early and continue across all phases.

Near-term benchmark work should include:

- defining a benchmark harness around `Codex` and `Claude Code`
- creating a baseline task suite in `TypeScript`
- measuring intervention-free completion, total tokens, repair loops, and time-to-green
- expanding into real app-building tasks on a moderate SaaS codebase, because that is the benchmark that matters most for `Clasp`
- splitting machine-readable page metadata from the default SSR HTML projection so benchmark tasks do not degrade into runtime or test-surface debugging
- generating host-binding adapters and seeded fixtures from compiler-known declarations so benchmark product changes stay inside the app surface
- adding mixed-stack scenarios where `Clasp` is the primary semantic layer while `JS`, native, SQL, or provider runtimes remain behind typed boundaries
- adding later benchmark variants that compare semantic compiler artifacts against raw text- and browser-only workflows
- expanding later into trust-boundary, control-plane, workflow, LLM-output, and external-objective adaptation benchmarks
- testing compact-syntax candidates against more verbose alternatives before committing to a final Clasp surface

Benchmark results should influence language and platform prioritization throughout the project.
