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
- Add proof-preserving semantic propagation and autofix planning for compiler-known declarations so routine cross-stack changes stop depending on manual file hunting
- Add staged checking tiers so local/interface checks, affected-surface verification, and full verification can run at different costs and latencies
- Add obligation discharge guidance so unresolved proofs and unsafe boundaries come with concrete refinement options, missing evidence, and bounded choice points
- Add transactional semantic edits so compiler-known changes can be previewed, applied atomically, and rolled back coherently when downstream verification fails
- Add semantic proof and result caching keyed by graph identity, compiler version, and relevant world or environment state so already-discharged reasoning does not repeat unnecessarily
- Add shared semantic primitive aliases and nominal domain types so ordinary function signatures stop defaulting to bare `Str`, `Int`, and `Bool`
- Treat primitives as representation-only beneath the source language rather than as a normal source-level escape hatch for project-facing declarations
- Add compiler guidance that promotes repeated local semantic aliases into canonical shared `Domain/` modules and flags competing file-local wrappers for the same concept
- Keep local bindings on the semantic type path as well, so agents do not regain a primitive escape route simply by packing more logic into larger functions
- Add protocol or trait declarations for shared behavior contracts without inheritance
- Add attached methods or receiver syntax as sugar over ordinary functions and protocol implementations, without turning classes or mutable object identity into the default programming model

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
- Add a root `clasp.toml` project manifest and workspace model so packages, source roots, targets, profiles, and foreign dependency metadata live in one compiler-known graph
- Add a `clasp.lock` lockfile and reproducible dependency-resolution pipeline for both Clasp packages and foreign package graphs
- Add compiler-managed foreign package imports so `npm` and `TypeScript` ecosystems can be consumed through typed manifests, declaration ingestion, and generated adapters instead of handwritten glue
- Add compiler-managed `Python` package and module interop as typed worker or service boundaries with generated schema bindings, transport, and lifecycle management
- Add compiler-managed `Rust` crate or native-library interop for performance-critical extensions, using generated bindings, capability metadata, and target-aware build integration
- Add one compiler-managed package workflow that syncs manifest-declared `Clasp`, `npm`, `Python`, and `Rust` dependencies through generated host projections instead of manual multi-tool setup
- Treat untyped or weakly typed foreign values as explicit boundary-only `Dynamic` or `Unknown` values rather than ambient `Any`
- Require explicit unsafe refinement when the compiler cannot prove a foreign declaration matches the claimed `Clasp` type
- Preserve blame-carrying boundary diagnostics so runtime type failures identify the exact foreign import, declaration, expected type, observed path, and unsafe assertion site
- Prefer protocol- and function-oriented polymorphism over class hierarchies when the language needs reusable behavior organization

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
- Reject bare primitives on schemas, routes, tools, pages, workflows, storage models, and other shared boundary surfaces so project-level meaning must stay explicit
- Start separating untrusted content from authority-bearing instructions and capabilities
- Keep unsafe, foreign-trusted, and unresolved values quarantined so trust and blame remain explicit through downstream use sites
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
- Add compiler-known resource-budget semantics for compute, model spend, storage, network, concurrency, and rollout blast radius instead of leaving cost and quota behavior to host-side convention
- Add deploy/runtime attestation and provenance reporting so compiled artifacts, deploy projections, execution environments, and world snapshots can state exactly what was built, where it ran, and what still had to be trusted
- Add generalized delegated capability handles for tools, deployment rights, budgets, and environment authority rather than limiting attenuation and delegation to secrets alone
- Add counterfactual impact preview queries so agents can ask what declarations, proofs, policies, migrations, rollouts, and runtime checks would change before editing
- Add interference and commutativity analysis so the compiler can decide when parallel change plans can proceed independently and when they must serialize
- Add minimal valid context-pack synthesis so the compiler can produce the smallest sound semantic neighborhood for a change, failure, or objective instead of forcing repository-wide search
- Add affected-surface verification planning so only the tests, sims, evals, proofs, and rollout gates that a change can actually invalidate are run in the fast path
- Add graph-bound semantic memory with automatic invalidation when the declarations, policies, or workflows it depends on change
- Add semantic ownership or lease primitives so parallel agents can coordinate responsibility over declarations, workflows, policies, and rollout surfaces
- Add cheapest-valid-path planning so the compiler can suggest the smallest legal change plan and cheapest sufficient verification path for a requested objective
- Add trusted computing base reporting so proofs, simulations, and deploy projections state exactly which compiler, runtime, host, foreign, or snapshot assumptions still had to be trusted
- Add a typed interactive session model so turn state, resumability, interrupts, cancellations, approvals, and human handoff stop living in ad hoc runtime state
- Add a unified plugin, hook, command, tool, and skill ABI with compatibility checks, capability metadata, and upgrade rules instead of independent extension silos
- Add first-class host-surface semantics for workspaces, filesystem actions, git operations, patch application, undo, and merge lifecycles so agent operating-system behavior is compiler-known
- Add explicit human-in-the-loop protocol semantics for approvals, escalation, explanations, and reversible actions instead of leaving them to UI convention

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
- Add a runtime-managed lightweight scheduler that can execute isolated processes or workflows in true parallel across cores while preserving mailbox ordering, supervision, and upgrade safety guarantees
- Add deterministic simulation and dry-run support for routes, workflows, agent loops, policy decisions, and temporal behavior using declared fixtures and simulated time
- Add world snapshots that capture the relevant external state for replay, simulation, and counterfactual preview instead of relying only on in-memory fixtures

Exit criteria:

- Long-running programs remain type-safe and replayable across restarts.
- Hot upgrades follow supervised, BEAM-inspired handoff rules rather than arbitrary in-place mutation.
- The runtime can scale from concurrency-only execution to real parallel process scheduling without changing the workflow or supervision model.

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
- Add first-class subagent spawn, join, supervision, and handoff semantics with delegated capabilities and scoped context packs
- Add turn-level context economics and compaction planning so interactive sessions and subagent trees can choose what to retain, summarize, or drop based on semantic relevance and token cost
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
- Add cross-repo and cross-package semantic-graph federation so objectives, policies, proofs, and rollout reasoning can extend beyond one repository or package graph
- Add declarative learning loops that tie incidents, failure clusters, evals, benchmarks, budget limits, and bounded remediation plans together instead of relying on ad hoc postmortems
- Add stronger behavioral verification hooks over workflows, policies, rollouts, and concurrent change plans using simulations, model-checking, or other bounded analysis where it materially improves confidence

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
- Keep the first self-hosted compiler path running on a JavaScript host runtime
- Add stage1 and stage2 bootstrap checks so the compiler can compile itself reproducibly
- Promote the hosted compiler from the proof-harness example tree into a real compiler implementation tree
- Switch ordinary compiler commands to the Clasp compiler by default while retaining an explicit Haskell bootstrap fallback
- Quarantine the Haskell bootstrap compiler behind an explicit recovery-only mode so ordinary workflows cannot silently escape back to the easier path
- Remove the Haskell bootstrap compiler from default development, CI, release, and benchmark paths once the self-hosted compiler proves stable enough

Exit criteria:

- The primary compiler implementation is written in `Clasp`
- The ordinary `check`, `compile`, and `explain` entrypoints default to the Clasp compiler rather than a self-hosting-only special case
- The Haskell compiler is no longer part of ordinary development or benchmark paths and remains only as an explicit recovery/bootstrap oracle
- Bootstrap reproducibility checks pass for the self-hosted path

## Phase 13: Native Backend and Bytecode Emission

- Add a backend-oriented native IR beneath the lowered IR
- Define a runtime ABI and data layout for native execution
- Define an explicit native memory-management strategy, allocation model, and ownership rules instead of leaving memory behavior implicit in host runtimes
- Define native object layout, root discovery, and lifetime invariants for the chosen memory strategy before code generation expands the runtime surface
- Emit real backend-native bytecode or native-target IR instead of depending only on JavaScript for server workloads
- Support the same compiler-owned boundary projections on the native path, including later binary codecs where they matter for backend transport
- Run the self-hosted compiler and backend services through the native path

Exit criteria:

- `Clasp` can run backend/compiler workloads without Bun
- The native path shares the same front end and type system as the JS path
- The native runtime has an explicit memory model and object-lifetime story rather than quietly depending on ambient host GC behavior
- Backend benchmarks can compare JS/Bun and native execution on the same language implementation

### First Native Memory Model

The first native runtime slice for compiler and backend workloads should stay explicit and narrow:

- handle-backed values use deterministic reference counting
- immediate values and activation records stay in stack storage while handle-backed values allocate in heap storage
- module globals stay in static storage and act as permanent roots for shared runtime state
- callees borrow incoming arguments and transfer returned handle ownership back to the caller
- records, variants, and lists retain the handle-backed fields or payloads they capture so aggregate lifetimes stay explicit
- every heap object starts with a two-word header containing a layout identifier and retain count before the object payload
- root discovery walks static globals, active stack handle slots, and layout-declared child offsets inside heap objects
- retain and release only visit handle slots declared by the object layout, and release walks those child roots before freeing storage
- ship a small native runtime bundle with explicit retain/release helpers, static-root registration, generic object allocation, and compiler-support text/path/file primitives
- keep the lowest native runtime layer in `C` with a narrow ABI instead of embedding the Haskell RTS into production server/runtime targets
- build higher-level supervision, upgrade, workflow, and compiler behavior in `Clasp` on top of that kernel rather than growing the kernel into a second application platform

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
