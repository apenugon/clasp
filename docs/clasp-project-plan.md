# Clasp Project Plan

## Purpose

This document turns the current design docs into a concrete implementation program for a swarm of agent worktrees.

It is intentionally more operational than the long-form design note. The goal is to answer:

- what order to build things in
- what can run in parallel
- what each agent task should look like
- what the milestone checkpoints are

## Current State

As of `v0.01`, the repo already has:

- a Haskell compiler scaffold
- parser, checker, typed core, and lowered IR
- algebraic data types and exhaustive constructor matching
- records, imports, foreign bindings, routes, and JSON boundaries
- JavaScript emission
- Bun-backed route runtime helpers
- an initial benchmark harness and first benchmark snapshot
- an experimental autopilot supervisor for builder/verifier agents

The current gaps are not just language features. The project also needs:

- smaller, better-scoped agent tasks
- stronger compiler and runtime semantics
- stronger correctness semantics beyond plain structural typing
- an explicit agent intermediate representation instead of runtime-specific planner JSON
- stronger first-class authorization and provable data-access mediation
- richer full-stack and AI-native surfaces
- a native storage model rather than ORM-shaped wrappers
- a better control-plane story
- built-in context graphs rather than repository search as the main relevance mechanism
- benchmark coverage broad enough to justify the language

## First Credible Benchmark Target

The first public proof point should not wait for the entire long-term platform.

It should be a benchmark-ready moderate SaaS slice where:

- `Clasp` owns shared schemas, generated boundary validation, backend logic, generated clients, and one AI/tool boundary
- the tasks require coordinated frontend, backend, and contract changes
- the first compiler-owned page and styling layer defaults to safe SSR output and typed styling semantics while leaving room for later explicit client modules or island-style interactivity
- at least one host/runtime boundary remains in play so interoperability is being tested rather than wished into existence
- the same scenarios run against a practical `TypeScript` baseline, with `Python` variants where orchestration-heavy comparisons are useful

It should not wait for:

- full control-plane completeness
- durable hot-swap and self-update semantics
- self-hosting
- native backend work
- SQLite-backed persistence

That benchmark is the earliest result likely to persuade other people that `Clasp` is more than an interesting compiler prototype.

## Swarm Operating Model

The swarm should not consume large roadmap bullets directly. It should consume small task files with explicit likely files, acceptance, and a single verification gate.

Every task should obey these constraints:

- one focused behavior change
- usually `2-6` source files plus tests
- one exact verification command
- one clear owner worktree
- no open-ended "add support for X everywhere" wording

Every task file should include:

- goal
- why it matters
- scope
- likely files
- acceptance
- verification command
- dependencies

Task sizing guidance:

- `XS`: parser-only, emitter-only, docs-only, or test-only changes
- `S`: one feature slice across parser/checker/emitter/tests
- `M`: one feature slice plus runtime/docs/benchmarks
- `L`: do not dispatch to one agent; split first

Worktree rules:

- one worktree per task
- no shared mutable state between worktrees
- verifier runs from a clean copy of the last accepted snapshot
- merge only after verification passes
- failed tasks produce structured reports, not free-form notes

## Milestones

### M1: Core Language v0.1

Outcome:

- a compact but still bootstrap-readable language core with enough local control flow and data modeling to build nontrivial application logic

Exit criteria:

- lists, lets, operators, and better diagnostics land
- formatter and explain-mode scaffolding exist
- agent task throughput is stable on small compiler tasks

### M2: Full-Stack App Slice

Outcome:

- one Clasp codebase can define shared data, typed routes, HTML views, and one small browser-plus-backend app that a human can click through

Exit criteria:

- a compiler-owned HTML/page rendering model lands with SSR-first emission
- the compiler-owned UI surface does not normalize raw host `class` or `style` strings as the default styling model
- typed actions, forms, redirects, and navigation contracts exist for the benchmark slice or are one narrow task away
- the page/runtime foundation preserves a path to later client-side reactivity and placement decisions without treating arbitrary active content as safe default page output
- schemas expand past the current record-only boundary story
- one end-to-end demo app runs from shared contracts and serves real pages

### M2.5: First Credible Benchmark

Outcome:

- one benchmark-ready moderate SaaS slice proves whether agents can ship real feature changes more effectively in `Clasp` than in a baseline stack

Exit criteria:

- mirrored `Clasp` and baseline repos exist for the benchmark slice
- both repos expose a browser-runnable click-through flow for the benchmark slice
- benchmark tasks cross frontend templates, backend logic, shared contracts, and one AI/tool boundary
- at least one interop edge is explicit and typed rather than ad hoc
- the benchmark slice emits enough machine-readable UI, boundary, or context artifacts that agents are not limited to text search and browser scraping alone
- benchmark outputs include intervention-free completion, total tokens, repair loops, and time-to-green
- at least one public-ready benchmark summary can be reproduced

### M3: Trust-Boundary Platform

Outcome:

- Clasp-generated validators handle most runtime trust boundaries automatically

Exit criteria:

- list/option/enum/nested schema codecs work
- config, tool IO, and persisted state boundaries use generated validation
- boundary schemas remain transport-neutral, with `JSON` as the first projection rather than the only long-term wire format
- invariant or constrained-value checks can be declared once and enforced automatically at boundaries
- protected values can carry data classification or disclosure constraints rather than being treated as ordinary fields
- provenance and secret-aware handling begin to exist

### M4: Control Plane in Clasp

Outcome:

- repo memory, permissions, commands, hooks, agents, verifier rules, traces, and static context graphs are first-class artifacts in Clasp

Exit criteria:

- Clasp can project executable machine manifests, machine protocol artifacts, and human docs from those declarations
- runtime policy enforcement is generated from the same source of truth
- static context-graph queries can resolve relevant declarations, capabilities, and policy gates
- app-facing authorization proofs and policy decisions are traceable through the same semantic model rather than hidden in framework middleware

### M5: Durable Self-Updating Workflows

Outcome:

- Clasp can model long-running workflows with checkpointing, replay, controlled hot-swap, bounded self-update, and runtime execution-graph semantics using BEAM-inspired supervision and upgrade semantics

Exit criteria:

- checkpoint/resume works
- module compatibility checks exist
- hot-swap is supervised rather than arbitrary
- supervisor and upgrade-handler semantics exist for long-running processes or workflows
- old and new code versions can coexist briefly during controlled upgrade handoff

### M6: AI-Native Platform

Outcome:

- Clasp expresses typed prompts, tool interfaces, provider strategies, eval hooks, safe model boundaries, and graph-addressable AI context natively

Exit criteria:

- one real agent app is built in Clasp
- benchmark suites cover model/tool workflows, not just typed HTTP changes
- a stable compiler-owned AIR exists so higher-level planners and generated workflows target one semantic representation before runtime execution

### M7: External-Objective Adaptation

Outcome:

- Clasp can map typed runtime or external feedback back to code, prompts, policies, rollout logic, and objective-graph structure

Exit criteria:

- metrics, goals, rollouts, and rollback gates are first-class enough to benchmark
- objective-graph queries can connect external signals to affected declarations, tests, evals, and rollout gates

### M8: Moderate SaaS App Without A Database

Outcome:

- one moderate SaaS application is built primarily in `Clasp`, using generated routes, generated validation, and shared type/schema definitions across the entire app surface

Exit criteria:

- a frontend, backend, worker or workflow path, and AI feature all run from one `Clasp` codebase
- the app relies on in-memory or file-backed state rather than a database so the language surface itself is the thing being tested
- benchmark tasks now include real app feature work rather than only compiler and schema slices

### M9: Hosted Self-Hosted Compiler

Outcome:

- the primary compiler implementation is written in `Clasp` and runs through the `JS/Bun` path

Exit criteria:

- the parser, checker, and emitter are ported enough for a real compiler path in `Clasp`
- bootstrap stage checks pass
- Haskell remains only as the bootstrap fallback

### M10: Native Backend And Bytecode Emission

Outcome:

- Clasp emits a real backend-native bytecode or native-target IR path for server and compiler workloads

Exit criteria:

- a backend-oriented native IR and runtime ABI exist
- the compiler and backend demos can run without Bun
- the same front end and type system drive both JS and native backends

### M11: Native Storage With SQLite First

Outcome:

- Clasp has a language-native typed storage model with SQLite as the first backend, and the SaaS app can persist real state

Exit criteria:

- typed connection, query, transaction, and migration surfaces exist
- schema-derived storage constraints exist where the storage backend can enforce them
- raw SQL remains an explicit unsafe or foreign boundary rather than the default query model
- the SaaS app runs with SQLite-backed persistence
- persistence-bearing app benchmarks land

## Dependency Order

The high-level dependency chain should be:

1. Swarm infrastructure stabilization
2. Core language slices
3. Better diagnostics and formatting
4. Richer schemas and trust boundaries
5. Full-stack route clients and app runtime
6. First credible benchmark on a moderate SaaS slice
7. Control-plane declarations
8. Static context-graph emission and queryability
9. Durable workflows and hot-swap
10. AI-native provider/tool/eval features
11. External-objective adaptation
12. Moderate SaaS app dogfooding and app-level benchmarks
13. Hosted self-hosting
14. Native backend and bytecode emission
15. SQLite persistence
16. Expanded benchmarks across all layers

Parallelism guidance:

- parser/checker/emitter slices can run in parallel only when they touch disjoint features
- diagnostics and benchmark tasks can usually run alongside core compiler work
- control-plane work should begin only after schema and trust-boundary foundations are credible
- context-graph work should begin as soon as declarations, schemas, and capabilities are stable enough to emit useful identifiers and edges
- workflow and hot-swap work should begin only after control-plane and type-boundary machinery exist
- the moderate SaaS app should begin only after the full-stack and trust-boundary layers are real enough to carry product logic
- the first credible benchmark should cut across tracks 1, 3, 4, 7, 9, and 10 before later platform layers become dominant
- self-hosting should begin only after the language is comfortable enough to express compiler code without constant workaround churn
- the native backend should trail the hosted self-hosting path rather than compete with it too early

## Critical Path To The First Credible Benchmark

The first benchmark that matters should be built from a narrow cross-track slice rather than from the entire roadmap.

Critical path:

- core ergonomics that make app code comfortable enough to write and modify
- schemas and trust boundaries that prevent contract drift from being benchmark noise
- generated route clients and runtime helpers that let one codebase span client and server concerns
- explicit interop boundaries so `Clasp` can coexist with practical host runtimes during the first benchmark
- one moderate SaaS slice that agents can actually evolve under test
- benchmark packaging that measures product-feature throughput rather than compiler microbenchmarks alone

## Full Backlog

### Track 0: Swarm Infrastructure

- `SW-001` Replace the current coarse `agents/tasks` backlog with a granular task manifest template and task schema.
- `SW-002` Add tests for autopilot queue behavior, especially blocked-task handling, workaround generation, and restart behavior.
- `SW-003` Add prompt-building tests so builder/verifier scripts cannot regress into shell interpolation or oversized prompt failures.
- `SW-004` Add run-state summaries and machine-readable status output for the supervisor.
- `SW-005` Add a merge gate that copies only verified workspace changes into the accepted snapshot.
- `SW-006` Add worktree lifecycle cleanup and stale-run garbage collection.
- `SW-007` Add task batching and dependency labels so multiple agents can be launched safely in parallel.
- `SW-008` Add a dashboard or summary script for pass rate, timeout rate, and mean time per task family.

### Track 1: Core Language Surface

- `LG-001` Land list types in the syntax tree and parser.
- `LG-002` Land list typechecking rules for homogeneous lists.
- `LG-003` Land lowering, emission, and JSON boundary support for lists.
- `LG-004` Add list-focused examples and parser/checker/emitter tests.
- `LG-005` Land local `let` expressions in AST and parser.
- `LG-006` Land `let` typechecking and lowering.
- `LG-007` Add `let` examples and tests.
- `LG-008` Land equality operators for `Int`, `Str`, and `Bool`.
- `LG-009` Land integer comparison operators for branching.
- `LG-010` Add parser precedence and checker rules for the first operator set.
- `LG-011` Add diagnostic fix hints for the current structured error set.
- `LG-012` Add block expressions as the first imperative-adjacent surface form.
- `LG-013` Add local variable declarations inside blocks.
- `LG-014` Add assignment for explicitly mutable locals only.
- `LG-015` Add early `return` semantics in function bodies.
- `LG-016` Add loop or iterator sugar for common imperative control flow.
- `LG-017` Spike a compact module/header surface that removes low-value boilerplate.
- `LG-018` Add a canonical formatter for the current source form.
- `LG-019` Add `clasp explain` or equivalent expanded human-readable rendering.

### Track 2: Type System and Diagnostics

- `TY-001` Add `Option` as a first-class type and value model.
- `TY-002` Add `Result` as a first-class type and value model.
- `TY-003` Add type parameters for records, ADTs, and functions.
- `TY-004` Add wildcard and nested constructor patterns.
- `TY-005` Improve exhaustiveness checking and diagnostics for future pattern forms.
- `TY-006` Add better related-location data for cross-module interface mismatches.
- `TY-007` Add fix-suggestion metadata to machine-readable diagnostics.
- `TY-008` Add JSON-schema-like projections for types and diagnostics where helpful to tools.
- `TY-009` Add package-aware module resolution and stable module identity beyond the current flattened file-path model.
- `TY-010` Add a compiler daemon and machine-native protocol, with LSP/editor adapters built on top.
- `TY-011` Add typed effect and capability annotations shared across functions, tools, and workflows.
- `TY-012` Add constrained or refinement-style value types for application-level invariants.
- `TY-013` Add compiler-known typestate or state-machine declarations for UI, workflow, and domain transitions.
- `TY-014` Add semantic edit and refactor operations over compiler-known declarations and schemas.
- `TY-015` Add a stable compiler-known agent IR or AIR with graph identity and replay-friendly serialization.

### Track 3: Schemas and Trust Boundaries

- `SC-001` Introduce dedicated schema declarations separate from records.
- `SC-002` Derive validators/codecs from schema declarations.
- `SC-003` Add list schema support end to end.
- `SC-004` Add `Option` or nullable boundary semantics without reintroducing unchecked nulls.
- `SC-005` Add enum/ADT JSON codec support for nontrivial sum types.
- `SC-006` Add nested schema support.
- `SC-007` Add env/config decoding from schemas.
- `SC-008` Add persisted workflow-state codecs.
- `SC-009` Add tool input/output boundary validation from schemas.
- `SC-010` Add schema versioning and migration hooks.
- `SC-011` Add provenance tracking for trust-boundary values.
- `SC-012` Add secret-aware value wrappers and redaction rules.
- `SC-013` Add typed distinctions between untrusted and trusted values at runtime boundaries.
- `SC-014` Add invariant, precondition, and postcondition declarations tied to schemas and state transitions.
- `SC-015` Add transport-neutral schema projections with stable field identity and schema fingerprints.
- `SC-016` Add generated binary boundary codecs from schemas for efficient service, worker, and agent-to-agent transport.
- `SC-017` Add field-level data classifications and disclosure rules tied to schemas, policies, and projections.

### Track 4: Full-Stack Runtime and App Layer

- `FS-001` Generate typed route clients from route declarations.
- `FS-002` Add a browser/client runtime helper layer for generated route clients.
- `FS-003` Build the first shared frontend-plus-backend demo app in Clasp.
- `FS-004` Add static asset, head, and style-bundle strategy for generated JS output.
- `FS-005` Clean up the Bun runtime surface and formalize its generated binding contract.
- `FS-006` Add worker/job runtime scaffolding using the same type and schema model.
- `FS-007` Add first-class auth/session, principal, tenant, and resource identity primitives for application code.
- `FS-008` Define the React interop boundary for using generated Clasp code in frontend apps.
- `FS-009` Define the React Native or Expo bridge path for future mobile reuse.
- `FS-010` Add one mobile-adjacent demo that reuses shared Clasp business logic.
- `FS-011` Define a stable host-interop contract with structured capability identities for `JS`, native, storage, and provider-backed runtimes.
- `FS-012` Add a compiler-known style IR with design tokens, variants, target lowering, and explicit raw host-style escape hatches.
- `FS-013` Add typed page actions, forms, redirects, and navigation contracts for full-stack app flows.
- `FS-014` Add structured route identity plus typed path, query, form, and body declarations instead of raw string route edges.
- `FS-015` Emit machine-readable UI, action, and navigation graph artifacts for page-driven app flows.
- `FS-016` Add compiler-known authorization requirements and proof-carrying access for routes, pages, actions, queries, and tools.

### Track 5: Control Plane Declarations

- `CP-001` Design declarations for repo memory.
- `CP-002` Design declarations for commands and command capabilities.
- `CP-003` Design declarations for hooks and lifecycle triggers.
- `CP-004` Design declarations for agents and agent roles.
- `CP-005` Design declarations for tool servers and tool contracts.
- `CP-006` Design declarations for verifier rules and merge gates.
- `CP-007` Generate executable machine manifests and protocol artifacts from control-plane declarations.
- `CP-008` Generate human-readable docs from the same declarations.
- `CP-009` Enforce file, network, process, and secret permissions from declared policy.
- `CP-010` Add policy-decision traces and audit output.
- `CP-011` Add approval and sandbox policy surfaces as typed configuration, not shell convention.
- `CP-012` Build one repo-level Clasp control-plane demo that drives a real agent loop.
- `CP-013` Emit a queryable context graph and expose a stable machine protocol plus CLI/API adapters for agents and tools.

### Track 6: Durable Workflows and Hot Swap

- `WF-001` Add workflow declaration syntax and typed state modeling for isolated long-running processes.
- `WF-002` Add checkpoint/resume primitives.
- `WF-003` Add replay and idempotency semantics for message-driven workflows.
- `WF-004` Add deadlines, cancellation, retries, and bounded backoff.
- `WF-005` Add degraded-mode and operator-handoff semantics under supervision.
- `WF-006` Add module version identifiers, upgrade windows, and compatibility metadata.
- `WF-007` Add state migration hooks and explicit upgrade handlers for hot-swap boundaries.
- `WF-008` Add supervised module hot-swap protocol with a bounded old/new version overlap.
- `WF-009` Add self-update handoff, draining, and rollback rules for long-running agents.
- `WF-010` Add supervisor hierarchy declarations and restart strategies inspired by Erlang/BEAM.
- `WF-011` Add mailbox or message-queue semantics for long-running workflow processes.
- `WF-012` Add health-gated upgrade activation and rollback triggers.
- `WF-013` Build a demo workflow that survives restart and controlled module replacement under supervision.

### Track 7: AI-Native Platform

- `AI-001` Add a provider interface abstraction for model runtimes.
- `AI-002` Add typed prompt functions.
- `AI-003` Add structured output declarations and runtime validation.
- `AI-004` Add typed streaming and partial-result handling.
- `AI-005` Add typed tool declarations and tool-call contracts.
- `AI-006` Add provider strategies such as retry, fallback, and budget policy.
- `AI-007` Separate prompt content from authority-bearing policy and tool grants.
- `AI-008` Add prompt, trace, and tool-call secret redaction and provenance rules.
- `AI-009` Add eval hooks and trace collection.
- `AI-010` Add constrained dynamic-schema support where runtime-selected output shapes are necessary.
- `AI-011` Build one real Clasp agent app using typed tools and structured outputs.
- `AI-012` Add interoperability shims for systems like `BAML` where that lowers adoption friction.
- `AI-013` Add source-to-AIR and prompt-or-plan-to-AIR projection hooks for higher-level agent builders.

### Track 8: External-Objective Adaptation

- `EO-001` Add domain-object and domain-event declarations.
- `EO-002` Add metric and goal declarations.
- `EO-003` Add experiment and rollout declarations.
- `EO-004` Add rollback and kill-switch semantics.
- `EO-005` Add typed ingestion of external operational or business feedback.
- `EO-006` Add traceability from runtime signals back to routes, prompts, workflows, tests, and policies.
- `EO-007` Build one bounded external-feedback-to-change demo path.

### Track 9: Benchmark Program

- `BM-001` Expand the current TypeScript vs Clasp schema-propagation suite.
- `BM-002` Add the same suite for `Claude Code`.
- `BM-003` Add a Python baseline for agent-heavy orchestration tasks.
- `BM-004` Add full-stack change tasks that cross client, server, and typed boundaries.
- `BM-005` Add trust-boundary rejection benchmarks.
- `BM-006` Add control-plane and permission-containment benchmarks.
- `BM-007` Add workflow durability and replay benchmarks.
- `BM-008` Add hot-swap and self-update benchmarks, including supervised upgrades, rollback, and version-drain behavior.
- `BM-009` Add syntax-form A/B benchmarks for compact vs more verbose surfaces.
- `BM-010` Add external-objective adaptation benchmarks.
- `BM-011` Add benchmark result packaging and reproducible run manifests.
- `BM-012` Add benchmark tasks on the moderate SaaS app that measure real product-feature throughput.
- `BM-013` Add compiler-maintenance benchmarks on the hosted self-hosted compiler path.
- `BM-014` Add backend compile-time and runtime benchmarks comparing JS/Bun and the native backend.
- `BM-015` Add SQLite-backed product-change benchmarks on the dogfood app.
- `BM-016` Add mixed-stack semantic-layer benchmarks where `Clasp` interoperates with host runtimes.
- `BM-017` Add end-to-end correctness benchmarks for invariants, state transitions, and storage-backed changes.
- `BM-018` Add boundary-transport benchmarks comparing `JSON` and generated binary projections on the same schema model.
- `BM-019` Add semantic-artifact benchmarks comparing compiler-assisted workflows against raw text and browser-only workflows.
- `BM-020` Add authorization and data-access benchmarks proving protected reads, writes, and field disclosures require policy proofs.
- `BM-021` Add AIR-assisted planning benchmarks comparing raw-text tasking with workflows that target compiler-owned AIR.

### Track 10: SaaS Dogfooding

- `SA-001` Define the moderate SaaS app scope and product surface, explicitly without a database in the first version.
- `SA-002` Add in-memory or file-backed app state primitives suitable for the dogfood app.
- `SA-003` Build the core shared domain types, routes, and generated clients for the dogfood app.
- `SA-004` Build the primary user-facing flows in Clasp across frontend and backend.
- `SA-005` Add one worker or workflow-driven product path in the app.
- `SA-006` Add one AI-assisted product feature in the app using typed model and tool boundaries.
- `SA-007` Add deterministic seeded app fixtures for local development and benchmarks.
- `SA-008` Add full end-to-end tests for the moderate SaaS app.
- `SA-009` Package the app so an agent can build and modify it from one Clasp codebase.
- `SA-010` Use the app as the main public benchmark proving ground against TypeScript baselines.

### Track 11: Self-Hosting

- `SH-001` Define the self-hosting subset of Clasp and the boundary between bootstrap and primary compiler implementations.
- `SH-002` Add the standard-library surface needed by compiler code written in Clasp.
- `SH-003` Port formatter and diagnostic rendering helpers to Clasp.
- `SH-004` Port module loading and package-resolution logic to Clasp.
- `SH-005` Port the parser to Clasp.
- `SH-006` Port lowered IR helpers and the JavaScript emitter to Clasp.
- `SH-007` Port checker and type-inference logic to Clasp.
- `SH-008` Build the hosted Clasp compiler in Clasp and run it through JS/Bun.
- `SH-009` Add stage0/stage1/stage2 bootstrap reproducibility checks.
- `SH-010` Switch the primary compiler implementation to Clasp while retaining the Haskell bootstrap fallback.

### Track 12: Native Backend And Bytecode

- `NB-001` Define a backend-native IR below the current lowered IR.
- `NB-002` Define runtime ABI and data-layout rules for the native backend.
- `NB-003` Emit a first native bytecode or native-target IR path for compiler workloads.
- `NB-004` Add a minimal native runtime suitable for compiler and backend execution.
- `NB-005` Add code generation for functions, ADTs, records, and control flow on the native path.
- `NB-006` Add native support for the JSON and runtime-boundary features needed by the compiler and SaaS app.
- `NB-007` Run the self-hosted compiler through the native backend.
- `NB-008` Benchmark JS/Bun against the native backend on compiler and backend workloads.
- `NB-009` Add native support for compiler-owned binary boundary codecs and efficient service transport.

### Track 13: SQLite Storage

- `DB-001` Define the SQLite capability, permission model, and trust boundary.
- `DB-002` Add a typed SQLite connection/runtime surface.
- `DB-003` Add typed query and row-mapping support.
- `DB-004` Add schema migration and compatibility hooks for SQLite-backed apps.
- `DB-005` Integrate SQLite into the dogfood SaaS app.
- `DB-006` Add persistence-bearing benchmarks and failure-mode tests.
- `DB-007` Add schema-derived table declarations and generated database constraints.
- `DB-008` Add typed transactions, isolation boundaries, and mutation semantics for storage effects.
- `DB-009` Add explicit unsafe SQL escape hatches with typed row contracts and audit metadata.
- `DB-010` Add policy-aware queries, mutations, and proof-gated row or field access for protected storage models.

## Suggested Dispatch Waves

### Wave 1: Make the Swarm Effective

Dispatch first:

- `SW-001` through `SW-004`
- `LG-001` through `LG-011`

Reason:

- the current bottleneck is coarse task sizing and missing language basics for ordinary application logic

### Wave 2: First Real App Upgrade

Dispatch after Wave 1:

- `SC-001` through `SC-006`
- `FS-001` through `FS-005`
- `BM-001`, `BM-004`, `BM-005`

Reason:

- this is the minimum viable path to a stronger full-stack benchmark story

### Wave 3: Control Plane Foundations

Dispatch after Wave 2:

- `CP-001` through `CP-009`
- `BM-006`

Reason:

- the language thesis now explicitly includes agent memory, permissions, tool contracts, and verifier rules

### Wave 4: Durable Self-Updating Agents

Dispatch after Wave 3:

- `WF-001` through `WF-013`
- `BM-007`, `BM-008`

Reason:

- hot-swap and self-update are only meaningful once workflows and control-plane semantics exist

### Wave 5: AI-Native Platform and Objective Loops

Dispatch after Wave 4:

- `AI-001` through `AI-012`
- `EO-001` through `EO-007`
- `BM-002`, `BM-003`, `BM-009`, `BM-010`, `BM-011`

Reason:

- this is where Clasp either proves the broader thesis or collapses into being "just another typed language"

### Wave 6: Dogfood The Actual App

Dispatch after Wave 5:

- `SA-001` through `SA-010`
- `BM-012`

Reason:

- the benchmark that matters most is whether agents can build and evolve a real product in Clasp faster than in a baseline stack

### Wave 7: Hosted Self-Hosting

Dispatch after Wave 6:

- `SH-001` through `SH-010`
- `BM-013`

Reason:

- once Clasp can carry a real app, it is credible to ask it to carry its own compiler

### Wave 8: Native Backend

Dispatch after Wave 7:

- `NB-001` through `NB-008`
- `BM-014`

Reason:

- native backend work becomes much more tractable once the hosted self-hosting path is proven

### Wave 9: SQLite And Persistence

Dispatch after Wave 8:

- `DB-001` through `DB-009`
- `BM-015`
- `BM-017`

Reason:

- SQLite should be the first storage backend for a language-native persistence model after the stateless or in-memory app path is already credible

## Immediate Recommendation

Do not continue using the existing coarse `0002` through `0008` task files as the primary swarm backlog.

Replace them with the smaller backlog above, starting with:

- `SW-001`
- `SW-002`
- `SW-003`
- `LG-001`
- `LG-002`
- `LG-003`
- `LG-005`
- `LG-006`
- `LG-008`
- `LG-009`
- `LG-011`

That is the highest-leverage starting set for recovering agent throughput while still moving the language forward.
