# Clasp: AI-Native Universal Programming Language

## Name

The language is called `Clasp`.

The name reflects the core design goal:

- One thread of logic across frontend, backend, jobs, agents, and eventually mobile
- One shared type system and schema system across the whole product
- One coherent language rather than multiple stacks glued together

## Goal

Design a programming language that is optimized to be written, reviewed, and maintained by AI systems while still being practical for building real products across:

- Frontend web apps
- Backend services and APIs
- Background jobs and workflows
- Mobile apps
- LLM- and agent-driven systems

The target is not "fewest possible characters." The target is the fewest possible decisions per unit of meaning, with strong verification, predictable behavior, and broad interoperability.

## Core Thesis

The best AI-oriented language would be:

- Compact, but not cryptic
- Highly regular, with one obvious way to express common patterns
- Strongly typed, schema-first, and effect-aware
- Easy to compile, lint, diff, and transform semantically
- Portable across frontend, backend, workers, and eventually mobile
- Native to LLMs, tools, evals, and agentic workflows

The deeper goal is not merely "AI can write it." The goal is that the language itself reduces the number of places where types, schemas, workflows, and permissions can drift apart.

## Scope Of "Universal"

`Universal` should not mean every workload and every low-level component must be implemented directly in `Clasp`.

It should mean:

- `Clasp` is the primary semantic layer for most software-building agent work
- application logic, schemas, boundaries, workflows, policies, and AI/tool interactions share one compiler-known model
- specialized host ecosystems can remain behind typed, auditable foreign boundaries without turning the overall system into ad hoc glue

Non-goals for early universality:

- kernels, drivers, firmware, and hard real-time loops
- GPU kernels and heavy numerical or scientific compute
- host-locked engine or platform internals where `Clasp` is not the control layer

The bar is not "replace every substrate." The bar is "be the default system language for most agent-built software systems."

## Core Attributes

### 1. Small, regular grammar

The language should have:

- Very few syntax forms
- Minimal punctuation noise
- No context-sensitive parsing tricks
- Little or no syntactic sugar that creates multiple equally valid idioms
- Canonical formatting so the same code always renders the same way

This matters because AI systems perform better when the language has low ambiguity and low stylistic variance.

### 2. Dense semantics, not code golf

Token efficiency should come from:

- Type inference where it is safe
- Schema derivation
- Good defaults
- Uniform module/import rules
- Standard library support for common product tasks

Token efficiency should not come from symbolic cleverness or overly compressed syntax. A few extra characters are acceptable if they materially improve correctness and readability.

The syntax should still be more compact than conventional human-first languages. Boilerplate keywords, repeated declarations, and metadata that can be derived from file or package structure should be removed aggressively.

That means things like:

- avoiding mandatory file-level boilerplate when module identity can be inferred
- minimizing repeated words that add little semantic value
- preferring one compact canonical source form over verbose ceremony

### Canonical source and explain mode

`Clasp` should have one canonical source language, not separate human and AI languages.

The canonical source should be:

- compact
- regular
- semantically explicit
- optimized for model reasoning and transformation

Human readability should be supported through projections and renderers, not by forcing the source language itself to carry extra verbosity.

So `Clasp` should eventually support tools like:

- `clasp fmt` for canonical compact formatting
- `clasp explain` or a similar mode that expands syntax and diagnostics into a more human-readable form
- AST- or IR-aware pretty renderers for docs, code review, and debugging

The important constraint is that these are views over one language, not multiple peer syntaxes that can drift apart.

### 3. Strong static typing

The language should include:

- Type inference
- Algebraic data types
- Exhaustive pattern matching
- Typed errors or explicit result types
- Typed async and stream primitives
- Generic types without excessive complexity

This is one of the most important constraints for AI-generated code. The compiler should reject as many invalid states and interface mismatches as possible.

Clasp should aim for Haskell-grade safety as an outcome, without requiring Haskell-grade complexity in everyday usage.

In practical terms, that means:

- No implicit `null` or `undefined`
- Algebraic data types as a standard modeling tool
- Exhaustive pattern matching
- `Option` and `Result`-style modeling for absence and failure
- Immutable values by default
- Explicit effects and capabilities

For long-running programs, this matters even more. Workflows, agents, and background systems benefit disproportionately from strong typing because subtle interface drift compounds over time.

Informative diagnostics are part of the type-system design, not a separate concern.

Clasp should aim for compiler errors that are:

- precise about the location and source of the mismatch
- explicit about expected versus actual shapes
- aware of shared schemas and boundary contracts
- able to point to related declarations across modules
- structured so both humans and AI tools can consume them directly

The compiler should treat structured diagnostics as the primary output and human-readable prose as a rendering mode on top.

That means:

- stable machine-readable error codes
- spans and related spans
- expected versus actual type and schema data
- suggested fix metadata where possible
- optional `--explain` or pretty rendering for human-oriented output

In other words, diagnostics should be informative to agents by default and human-oriented when explicitly requested or rendered by tools.

### Semantic edits and refactors as first-class compiler artifacts

Agents should not be limited to raw text diffs forever.

If the compiler already understands declarations, schemas, routes, workflows, capabilities, and UI structure, then it should eventually expose machine-writable edit operations over that model.

That means things like:

- renaming a declaration safely across modules
- propagating a schema change through affected boundaries
- updating a route contract and regenerating impacted clients
- evolving a state transition or action contract
- moving declarations while preserving semantic identity

Those operations should come with:

- explicit preconditions
- affected-artifact summaries
- conflict or fallback metadata
- a stable machine format for proposed edits

Human-readable patches can still be rendered from that result, but the semantic operation should be first-class.

### 4. First-class schemas

Schemas should be a central language concept, not a library convention.

The same schema definitions should drive:

- API inputs and outputs
- Database models
- Events and queues
- UI forms
- Agent tool interfaces
- Structured LLM output validation

This removes a major source of duplication across full-stack systems.

The important design goal is not just shared types, but a shared source of truth. Frontend, backend, mobile, workers, workflows, and agents should all derive their contracts from the same definitions rather than manually copying shapes across layers.

### Imperative surface, typed core

`Clasp` does not need to stay human-facing functional in its final source form.

For adoption, it is probably better if the surface language feels more imperative and product-oriented:

- local variables
- assignment where appropriate
- block syntax
- explicit early return
- loops or iterator sugar
- async-style control flow

That does not require giving up the stronger type model.

The right architecture is:

- an imperative or hybrid surface language for day-to-day authoring
- a smaller typed core underneath that remains easier to analyze, verify, and compile

So the long-term goal should be mainstream ergonomics at the source level without giving up the semantic rigor that makes the language valuable for agents.

## Type System and Trust Boundaries

### Shared types everywhere

One language everywhere should mean:

- One type system
- One schema model
- One package system
- One set of contracts for data, actions, and workflows

The main win is that application code does not have to constantly cross hand-maintained type boundaries between frontend and backend, or between workflow code and agent code. Everything inside the Clasp world should use the same definitions.

### Stable module identity, not just filesystem paths

Agents should not have to treat the repository layout as the primary semantic namespace.

`Clasp` should move toward:

- package-aware module identity
- stable graph addresses for declarations and modules
- imports that survive routine file moves and refactors
- projection paths from semantic identity to filesystem layout, not the other way around

File paths will still matter operationally, but they should not remain the only durable notion of identity in the language or tooling model.

This applies to:

- UI state
- API handlers and clients
- Database-facing models
- Queue payloads
- Workflow state
- Agent actions
- Tool interfaces
- Model input and output schemas

### Real boundaries still exist

Even with one language everywhere, trust boundaries still exist at runtime.

Those boundaries include:

- HTTP requests and responses
- Database reads and writes
- Persisted workflow state
- Queue and event payloads
- Environment variables and config
- File input
- FFI calls
- LLM responses
- External tool results

So the correct Clasp model is not "there are no boundaries." The correct model is:

- There should be no duplicated manual type definitions across the system
- There are still real trust boundaries where untrusted data enters the typed world

### Generated boundary validation

Runtime validation should be derived from the same types and schemas at compile time.

The compiler should automatically generate:

- Validators
- Decoders
- Encoders
- Serializers
- Deserializers
- Schema metadata
- Transport-projection metadata and stable schema identities
- Migration hooks where needed

The runtime should automatically execute those generated checks only when values cross trust boundaries.

That means:

- Internal typed Clasp code should not keep re-validating already trusted values
- Untrusted inputs should be validated automatically before they become typed values
- Once validation succeeds, the program can treat the value as a normal typed value

This is not like a garbage collector. A better model is automatic boundary enforcement driven by compile-time schema derivation.

That schema model should also stay transport-neutral.
`JSON` is the right first boundary format for debugging, interop, and the first benchmark, but it should not become the permanent semantic foundation for every runtime boundary.
The same compiler-owned schema should be able to project to:

- `JSON` for web and human-inspectable boundaries
- binary formats such as `protobuf`-compatible messages where compact transport matters
- potentially a `Clasp`-native compact binary format later if that proves better for deterministic agent-to-agent or service-to-service communication

The important part is that `Clasp` owns the schema and the boundary contract first, while wire formats remain generated projections rather than the source of truth.

### Prove what can be proved, make the rest explicit

The right correctness target for `Clasp` is not to pretend that every real app property can be solved statically.

The right target is:

- prove closed-world invariants at compile time where the program model is rich enough
- generate runtime checks automatically where values cross open-world trust boundaries
- make every remaining unproven assumption explicit in types, capabilities, storage boundaries, or effect surfaces

This keeps the semantic model honest.
Browsers, databases, users, clocks, networks, and models are still real runtime actors.
But they should enter the system through typed, auditable surfaces rather than through unstructured escape hatches.

### Refinement and constrained value types

Shared schemas are necessary, but not sufficient for application correctness.

The language should eventually support constrained or refinement-style value modeling for cases like:

- non-empty strings
- validated email or URL values
- positive or bounded integers
- money and unit-safe quantities
- normalized IDs and strongly distinguished identifier types
- value ranges that matter to UI, business logic, and storage alike

Where possible, the compiler should prove these constraints statically.
Where values arrive from external boundaries, the compiler should generate the corresponding validators automatically rather than relying on ad hoc user code.

### Typestate and protocol correctness

Many full-stack bugs are not simple shape mismatches.
They are illegal state transitions.

So `Clasp` should eventually support compiler-known state-machine or typestate declarations for:

- UI and page flows
- form and action submission lifecycles
- business-object state transitions
- workflow and job progression
- tool and model interaction protocols

This should let the compiler reject invalid transitions such as:

- navigating to a page state that cannot exist yet
- returning a review result for an object that was never submitted
- reusing a completed one-shot token
- applying an action that is illegal for the current state

### LLMs and agents as typed but untrusted edges

LLM and agent systems are one of the strongest reasons to design Clasp this way.

Clasp should allow developers to declare:

- Expected model input structures
- Expected output schemas
- Tool interfaces
- Workflow state transitions
- Action result contracts

But model outputs should still be treated as untrusted until validated.

The right flow is:

- A prompt or action declares an expected schema
- The compiler derives the validator
- The runtime applies the validator automatically
- The result becomes either a trusted typed Clasp value or a typed failure

So LLM support in Clasp should feel native and strongly typed, while still preserving the reality that model outputs are probabilistic external data.

### Long-running programs

For durable workflows, agents, and long-lived systems, type safety is necessary but not sufficient.

Clasp should also support:

- Typed persisted workflow state
- Versioned schemas
- Migrations for stored state
- Replayable execution
- Idempotent actions
- Explicit checkpoint and resume points

This is how "one language everywhere" remains safe over time instead of only at initial compile time.

### Native storage, not a wrapped ORM

If `Clasp` is meant to provide end-to-end correctness across full-stack apps, storage should not stay as a library-shaped ORM bolted onto the side.

The stronger model is:

- one schema system for API, UI, workflow, and persisted data
- compiler-known storage declarations that lower to a concrete backend
- typed queries and row shapes
- typed transactions and mutation boundaries
- generated migrations and compatibility checks
- generated database constraints from the same schema and invariant model where possible

`SQLite` can be the first storage backend, but it should be the first backend for a language-native storage model, not just a nicer wrapper around handwritten SQL.

Raw SQL should still exist, but only through explicit host or unsafe escape hatches with typed contracts.

### Hot swap and self-update

`Clasp` should be designed for supervised hot swapping and self-update, especially for long-running agents and workflows.

The right semantic model here is closer to `Erlang` and the `BEAM` than to arbitrary live patching:

- isolated long-running processes or workflows
- supervisor-managed failure and restart
- mailbox or message-driven coordination rather than shared mutable state
- explicit upgrade handlers for state transition
- a bounded period where old and new code versions can coexist
- process draining and rollback rather than arbitrary in-place mutation

That means the language and runtime should eventually support:

- versioned modules
- typed state snapshots and resumes
- compatibility checks between old and new module versions
- generated migrations where possible
- explicit upgrade handlers for process or workflow state
- supervisor-directed restart and rollback policies
- mailbox-safe handoff semantics for long-running processes
- a two-version window for old and new code during upgrade
- explicit safe-to-swap points
- rollback if activation fails

Even the “core module” should be replaceable in principle, but not through arbitrary in-place mutation.

The safer model is:

1. Reach a verified handoff point.
2. Snapshot typed state and capabilities.
3. Load the new version beside the old one.
4. Validate compatibility and warm it up.
5. Switch authority.
6. Keep rollback live until health checks pass.

That approach is much more realistic for self-updating agents, durable workflows, and eventually robots or other embodied systems than trying to rewrite active logic at an arbitrary instruction boundary.

In other words, the hot-swap semantics should be inspired more by `BEAM` operational semantics than by "edit the code that is currently executing."

### 5. Explicit effects and capabilities

The language should make side effects visible and typed:

- Network access
- Database access
- File access
- Background jobs
- UI updates
- LLM/model calls
- Tool execution

This is critical for auditability, testing, security, and agent reliability.

### 6. Immutability and determinism by default

The default execution model should prefer:

- Immutable values
- Controlled mutation
- Deterministic semantics where possible
- Replayable workflows
- Stable concurrency rules

Agent systems are much easier to debug when behavior can be replayed and reasoned about.

## One Language Everywhere

This should be a non-negotiable design goal within the software-building domain.

The language should be usable across:

- Browser frontend
- Backend services
- Edge/runtime workers
- Background job systems
- CLI tools
- Mobile apps
- Agent runtimes

Coverage should be measured at the system layer, not by forcing every dependency, kernel, or host runtime to be rewritten in `Clasp`. The important test is whether the system's shared semantics live in one language and whether foreign edges stay typed and auditable.

The right interpretation is not "one runtime everywhere." It is "one language, one type system, one package system, one tooling surface, multiple compilation targets."

### 7. Shared semantics across targets

The same core language should mean the same thing everywhere.

A function, type, schema, workflow, or permission model should not have different semantics depending on whether it runs in the browser or the backend. Target-specific behavior should be explicit.

### 8. Multi-target compilation

The language should compile cleanly to:

- Browser-compatible output
- Server runtimes
- Worker/edge environments
- WASM where useful
- Mobile-native targets or strong bridges to Swift/Kotlin

Short term, strong JavaScript/TypeScript interop is essential. Long term, native mobile support matters more than ideological purity.

The right backend strategy is:

- JavaScript first, because it gives immediate coverage for frontend, backend, workers, and React Native
- a shared typed core and lowered IR beneath that
- future native backends, potentially including LLVM-oriented code generation, once the language semantics are stable enough to justify them

That means Clasp should not be designed as "a JavaScript-flavored language forever." It should be designed as a language with multiple emitters sharing one semantic core.

### 9. Shared UI and state model

For true full-stack viability, the language should have a coherent way to express:

- Components
- Reactive state
- Forms
- Routing
- Async data loading
- Streaming updates
- Offline/cache behavior
- Styling tokens, variants, and composition

For mobile, the same language should either:

- Compile to native UI layers, or
- Drive a high-quality cross-platform UI runtime

The important part is that application logic, types, schemas, permissions, and workflows are shared, even if rendering backends differ.

UI structure should not be compiler-known while styling remains ambient string soup.
If `Clasp` is meant to support compiler-managed SSR/CSR placement, cross-target UI reuse, and agent-friendly refactors, then styling semantics also need a compiler-owned model.

### Compiler-known styling, not ambient class strings

The long-term UI layer should treat styling more like typed data than like unstructured HTML attributes.

That means:

- first-class design tokens for color, spacing, typography, radius, layout, and motion
- first-class variants for responsive breakpoints, pseudo-state, theme, and state-driven branches
- composable style groups with stable identity in the semantic model
- target-specific lowering so the same style intent can become CSS/classes on the web, style objects on native surfaces, or other host renderers
- asset and head declarations that stay tied to the same semantic model as pages and components

The default model should not be free-form `class` or raw `style` strings.

Those raw host styling surfaces should still exist, but as explicit escape hatches such as:

- typed handles to imported host styles
- clearly marked `unsafe` or host-specific raw class/style escapes
- foreign or host-module boundaries for cases where the compiler should stop reasoning about portability

This matters for more than aesthetics.
It is what enables:

- deterministic extraction and dead-style elimination
- safe refactors over styling as well as structure
- future SSR/CSR and island placement decisions that can reason about style dependencies
- cross-target reuse beyond the browser
- lower cognitive load for agents compared with ad hoc class-string conventions

### 10. Full-stack primitives in the standard model

The language or its standard platform should understand:

- HTTP routes
- Auth/session concepts
- Data fetching
- Queues and jobs
- Realtime streams
- Local persistence
- Sync and conflict resolution
- Asset handling and deployment packaging

These should not all be left to unrelated third-party frameworks.

### Authorization as compiler-known semantics, not middleware convention

For the strongest guarantees, `Clasp` should go beyond generic RBAC helpers.

The semantic model should eventually include things like:

- principal identities
- tenant or scope identities
- resource identities
- action identities
- policy declarations over those identities
- proof or witness values produced when runtime auth facts satisfy a policy

That proof-carrying model should then apply across:

- routes
- page rendering
- actions and form handlers
- queries and mutations
- tool calls
- workflow steps

The key guarantee is not "auth exists somewhere in the stack."

The stronger guarantee is:

- protected reads and writes require explicit policy mediation
- protected fields cannot be rendered, queried, logged, traced, or sent to models without the right proof
- bypasses are explicit unsafe or foreign boundaries rather than accidental omissions

This is a much stronger target than framework middleware or stringly route guards, and it is a better fit for agent-built systems that need complete mediation and auditable authority.

### Structured routes and host boundaries, not stringly edges

Routes, host bindings, and foreign capabilities should not remain permanently modeled as raw strings.

The stronger long-term shape is:

- structured route identity
- typed path, query, form, and body declarations
- compiler-known handler and boundary metadata
- structured host capability identifiers and binding manifests
- explicit unsafe escapes where the compiler stops reasoning about the boundary

That gives agents something stable to query and transform, and avoids treating string literals as the main representation of important runtime contracts.

### UI graphs and action traces as first-class artifacts

If `Clasp` owns pages, actions, forms, navigation, and later client placement, then it should emit machine-readable UI artifacts too.

Those artifacts should cover at least:

- page and component identity
- action and form contracts
- navigation edges
- state and data dependencies
- rendering or hydration boundaries where relevant

That lets agents reason about product flows semantically instead of relying only on browser scraping or HTML inspection.

## AI, LLM, and Agent-Native Features

### 11. Typed model interactions

Model calls should not be loose stringly typed API wrappers.

The language should support:

- Typed prompts or structured prompt templates
- Typed structured outputs
- Tool definitions as typed interfaces
- Embedding/vector operations
- Multimodal inputs and outputs
- Model/provider abstraction without hiding important differences

This should absorb the strongest ideas from systems like `BAML` rather than forcing `Clasp` users into a second schema and prompt DSL.

In practice that means:

- Prompt-as-function declarations with normal typed inputs and outputs
- Structured output validation derived from the same schema system used elsewhere
- Typed streaming, including partial and incremental object materialization
- Provider/client strategies such as fallback, retries, round-robin, and budget policies
- Generated clients and UI-facing bindings from the same model declarations
- A constrained dynamic-schema mechanism for cases where part of the output contract is chosen at runtime

`Clasp` should interoperate with external systems like `BAML`, but it should not need a separate prompt-language universe just to express these semantics.

### 12. First-class agents and workflows

Agents should be represented as structured workflows, not just loops around a chat completion call.

The language should support:

- Tool calling
- Planning/execution loops
- State machines
- Long-running workflows
- Retries
- Timeouts
- Idempotency
- Compensation and rollback patterns
- Human-in-the-loop checkpoints

### `Clasp` as an agent intermediate representation

`Clasp` should not only be a source language.

It should also become a stable agent intermediate representation for higher-level systems such as:

- natural-language goal compilers
- prompt planners
- GUI or app builders
- semantic refactor tools
- workflow synthesis systems

That does not mean exposing the internal lowered backend IR directly.

It means exposing a compiler-known AIR that preserves stable identities for:

- schemas
- routes
- pages and actions
- workflows
- prompts
- tools
- policies
- capabilities

The important property is that source code, planner output, and generated app or agent structures can all converge on one semantic representation before execution.

That gives the ecosystem:

- replayable, serializable plans
- one stable target for semantic edits and graph queries
- less runtime-specific execution JSON
- cleaner benchmarking of source-first versus AIR-assisted agent workflows

## Agent Control Plane

Serious agent systems already rely on a control plane outside the programming language:

- Repo memory and instructions
- Permission policies
- Tool registries
- Commands and task entrypoints
- Hooks and event handlers
- Subagent definitions
- Verifier gates
- Machine-readable traces

If `Clasp` leaves those concerns as a permanent mix of Markdown, YAML, JSON, and shell, it gives up much of the advantage it is trying to earn.

### Small semantic core, rich declarative platform

`Clasp` should keep the expression and type core small.

The better structure is:

- A small semantic core for values, types, schemas, effects, modules, and workflows
- A set of compiler-known declarative platform constructs for the agent control plane
- A deterministic projection pipeline that emits docs, manifests, wrappers, traces, and runtime metadata

That keeps the language law small while still making the platform first-class.

### Machine protocols first, CLIs and docs as projections

The primary interface to the compiler and platform should eventually be a stable machine protocol, not only a collection of human-oriented CLI commands.

That protocol should support:

- checking
- compilation
- graph queries
- projection queries
- semantic edit requests
- refactor previews
- diagnostics and trace retrieval

CLI commands, browser tools, and human-readable docs should be projections over the same model. They are important, but they should not be the only durable interface agents can rely on.

### First-class control-plane declarations

The platform should eventually support declarations such as:

- `guide` for repository memory and instruction inheritance
- `policy` for permissions, approvals, and capability boundaries
- `command` for typed workflow entrypoints and operator actions
- `hook` for event-driven automation
- `agent` for named subagents with bounded authority
- `toolserver` for external tool and MCP-style integrations
- `verify` for repo-native success criteria and gated checks
- `trace` for standard execution and audit events

These declarations should:

- live in normal modules
- import the same business types and schemas as application code
- participate in the same package graph
- be validated by the compiler rather than interpreted as untyped sidecars

### Built-in context graphs

`Clasp` should emit first-class context graphs from the same semantic model used for checking, code generation, policy enforcement, and tracing.

These graphs should not be:

- a separate hand-maintained knowledge base
- a sidecar index built by scraping source text
- an editor-only feature disconnected from runtime behavior

They should be compiler-emitted artifacts that can be queried by agents, tools, runtimes, and operator-facing products.

The purpose is simple:

- let agents ask "what is relevant to this change?" without scanning the whole repository
- let external signals map directly to affected declarations
- let prompts and task contexts be built from the smallest valid semantic neighborhood
- let review, eval, rollout, and permission checks run as graph queries instead of heuristics

### Context graph layers

`Clasp` should eventually emit at least three related graph layers:

- a static context graph for modules, declarations, schemas, capabilities, and ownership structure
- a runtime execution graph for traces, side effects, failures, retries, approvals, and state transitions
- an objective graph for domain objects, metrics, goals, policies, experiments, and rollouts

These layers should share stable identifiers so a runtime event can be traced back to:

- source declarations
- controlling policies
- affected business or domain objects
- tests, evals, and rollout gates

### Context graph nodes

Useful graph node kinds should include:

- module
- declaration
- type
- schema
- route
- workflow
- prompt
- model client
- tool
- agent
- command
- hook
- policy
- capability
- verifier rule
- test
- eval
- benchmark scenario
- domain object
- domain event
- metric
- goal
- experiment
- rollout
- runtime trace event

### Context graph edges

Useful graph edge kinds should include:

- `imports`
- `declares`
- `uses`
- `validates`
- `encodes`
- `decodes`
- `invokes_tool`
- `calls_model`
- `requires_capability`
- `reads`
- `writes`
- `emits`
- `handles`
- `traces_to`
- `gated_by`
- `measured_by`
- `affects`
- `owned_by`
- `rolls_out_with`
- `rolls_back_to`

The exact vocabulary can evolve, but the important constraint is that edge semantics should come from compiler and runtime knowledge rather than being guessed from names or comments.

### Why a language can matter here

This infrastructure can absolutely be built around other languages.

`TypeScript`, `Rust`, and `Python` can all support some combination of schemas, hooks, agent configs, and generated tooling.

So `Clasp` only earns the right to exist if it reduces entropy by making these concerns share one model:

- one schema system across product code, tools, prompts, workflows, and evals
- one module graph for code and control-plane declarations
- one compiler that understands both product semantics and operational metadata
- one capability model for effects, permissions, and tool authority
- one canonical source form for stable context, low-noise diffs, and reliable caching
- one diagnostics and trace protocol for both humans and agents

If `Clasp` does not do that, the same control-plane infrastructure can be bolted onto an existing language and the case for a new language becomes much weaker.

### 13. Evals as a built-in concept

Evals should be first-class, not bolted on later.

The platform should support:

- Dataset definitions
- Test cases for prompts, tools, and workflows
- Regression gates in CI
- Scoring functions
- Latency/cost/quality benchmarks
- Replay against historical traces

Without this, AI-heavy applications decay quickly.

### 14. Observability and replay

The platform should capture:

- Prompt inputs
- Tool calls
- Model outputs
- Intermediate state transitions
- Costs
- Latency
- Failures
- Versions of prompts, models, tools, and dependencies

This should make agent runs inspectable and replayable.

### Tooling products should consume first-class artifacts

Products like a playground, prompt inspector, eval runner, or trace browser should be official and excellent, but they do not need to be part of the semantic core.

What should be first-class instead is the data they depend on:

- Prompt IR
- Eval declarations
- Trace and event schemas
- Capability graphs
- Context graphs
- Deterministic fixtures and snapshots
- Provider strategy metadata
- Projection metadata back to source spans and declarations

That design keeps the core language small while making advanced tooling straightforward to build and keep correct.

## External-Objective-Native Adaptation

The long-term goal for agent systems is not merely to edit files faster.

Agents will increasingly be asked to change software in response to:

- Market feedback
- Conversion data
- Support escalations
- Sales notes
- Quality regressions
- Safety incidents
- Cost and latency pressure

Those signals are expressed in business terms, not file paths.

More generally, they are expressed in external terms rather than code terms.

So `Clasp` should be designed so agents can operate on domain objects, policies, and real-world targets as the stable substrate of the system.

Business objects are one especially important subset of this broader class, but the same model should also cover:

- safety objectives
- compliance requirements
- operational reliability targets
- latency and cost budgets
- scientific or product-quality metrics
- human approval and escalation policies

### Business objects should be first-class

The platform should eventually support first-class domain constructs such as:

- entities and records that represent durable business objects
- events that describe state transitions and external feedback
- metrics and goals tied to those objects and flows
- experiments and rollouts for bounded behavior changes
- policy and guardrail declarations tied to external outcomes

### Feedback should be typed against domain objects

The same schema system should model:

- request and response contracts
- persisted state
- workflow state
- tool inputs and outputs
- model outputs
- market feedback and operational events

That gives the compiler and runtime a shared way to answer:

- which business objects are affected
- which routes, prompts, workflows, and policies touch them
- which tests, evals, and rollout rules should gate changes

This should be implemented through graph queries over compiler-emitted semantic artifacts, not through ad hoc repository search.

### Mental model

The working loop should look like:

- external feedback or target
- typed domain signal
- affected business object, policy surface, or workflow
- affected declarations
- candidate change
- eval
- rollout
- new feedback

Or in one line:

`external feedback or target -> typed domain signal -> affected business object, policy surface, or workflow -> affected declarations -> candidate change -> eval -> rollout -> new feedback`

The compiler and tooling should eventually make it easy to answer questions like:

"This drop in enterprise lead conversion touches these business objects, these prompts, these routes, these policies, and these tests."

If `Clasp` cannot answer that kind of question directly from its semantic model, agents remain file editors rather than operators acting on external objectives.

## Verification and Trust

### 15. More than type safety

The language should support multiple layers of verification:

- Static types
- Refinement or constrained value checks
- Typestate and transition validation
- Preconditions and postconditions
- Assertions
- Schema validation
- Generated storage constraints and migration compatibility checks
- Property-based testing
- Deterministic test fixtures
- Permission checks
- Workflow invariants
- Information-flow and capability checks

Where it materially improves product-level guarantees, the platform should also leave room for solver-backed invariant checking rather than limiting itself to syntax-directed type rules alone.

### 16. Capability-based security

This matters even more for agent systems than normal applications.

Code should receive explicit authority to:

- Call external services
- Read or write data
- Execute tools
- Access user secrets
- Trigger side effects

Ambient authority is a poor fit for autonomous systems.

Least privilege should be the default, not an afterthought.

That means:

- capabilities should be explicit on workflows, commands, hooks, prompts, and tool integrations
- file, network, process, secret, and model authority should be separately grantable
- approval boundaries should be part of the semantic model, not shell wrapper behavior
- capability narrowing should be easy and capability escalation should be deliberate and auditable

For application data, this should eventually combine with authorization proofs and data classification so least-privilege applies not only to tools and side effects, but also to which rows, fields, and UI projections code is allowed to touch.

### Secrets, provenance, and data handling

`Clasp` should treat secrets and untrusted data as semantically distinct classes of values.

At a minimum, the platform should support:

- opaque secret values that are non-loggable and non-serializable by default
- provenance metadata for values that came from users, tools, models, files, queues, or external services
- policy hooks for redaction, retention, and disclosure
- clear separation between trusted instructions, untrusted content, and executable authority

This matters for both classical security and agent-specific risks such as prompt injection, tool misuse, and accidental secret exfiltration.

### 17. Robust failure semantics

Security is not enough if systems fail chaotically under pressure.

The language and platform should make it straightforward to model:

- explicit failure and absence types
- deadlines, cancellation, and timeout propagation
- retries with bounded policy and backoff
- circuit breakers and degraded-mode fallbacks
- idempotent actions and compensating actions
- operator handoff and kill-switch paths

Robustness should be expressed in program semantics, not hidden in ad hoc helper libraries.

### 18. Reproducible builds and execution

The system should have:

- Hermetic dependencies where possible
- Lockfiles
- Versioned schemas
- Versioned prompts and eval datasets
- Stable builds
- Stable compiler output

This is necessary for debugging and trust.

Where possible, the toolchain should also preserve provenance for:

- compiler version
- dependency graph
- emitted artifacts
- prompt, model, and eval versions
- policy and capability versions

## Tooling Optimized for AI

### 19. Machine-readable everything

The compiler and tooling should expose:

- Structured diagnostics
- ASTs
- Symbol graphs
- Context graphs
- Type information
- Prompt and workflow IR
- Trace schemas and execution events
- Capability graphs
- Projection manifests for docs, CLIs, hooks, and tool integrations
- Semantic diffs
- Refactoring APIs

AI systems should work against the semantic model of the codebase, not scrape error strings.

Context graphs are one of the clearest expressions of that rule.

They should let tools answer questions such as:

- what declarations are relevant to this runtime failure?
- what is the smallest safe context for this prompt or task?
- what capabilities can this workflow exercise?
- what tests, evals, and policies gate this rollout?
- what external objective does this change affect?

### 20. Canonical formatting and low-noise diffs

Formatting should be mandatory and stable. The language should minimize stylistic churn so both humans and AI can focus on behavioral changes.

### 21. Fast incremental compilation

If the language is meant for iterative AI-human collaboration, the feedback loop has to be fast:

- Fast typechecking
- Fast tests
- Fast eval runs
- Fast local preview for frontend/mobile changes

## Additional Attributes Worth Adding

These are not optional if the goal is a serious universal system language for software-building agents:

- Cost awareness for model usage, including budgets and policy limits
- Latency awareness for real-time UI and agent workflows
- First-class streaming for UI, server responses, and model outputs
- Offline-first support and sync semantics for mobile and edge cases
- Data lineage and privacy controls for AI features
- Secret classification, redaction, and provenance-aware policy enforcement
- Built-in context-graph emission and queryability across static, runtime, and objective layers
- Business-object graphs, metrics, goals, and rollout metadata
- Safe rollout, rollback, and kill-switch semantics for automated changes
- Resource budgets for time, cost, model usage, and side-effectful operations
- Built-in versioning and migration support for schemas, workflows, and prompts
- Excellent FFI so the language can adopt existing ecosystems instead of waiting for replacements
- A clear deploy model for web, backend, workers, and apps

## What to Avoid

- Optimizing purely for fewer BPE tokens
- Building a clever but opaque syntax
- Creating multiple equally valid styles for the same idea
- Hiding side effects behind convenience APIs
- Requiring separate languages for frontend, backend, and agents
- Making LLM support a thin SDK layer instead of part of the language model
- Treating the agent control plane as permanent sidecar YAML, Markdown, and shell glue
- Pushing core agent-platform semantics into ad hoc macros or metaprogramming
- Letting business feedback stay disconnected from the declarations that implement the business
- Giving autonomous code ambient access to files, network, tools, or secrets
- Treating prompt and tool injection as merely application-layer concerns instead of language and runtime concerns
- Allowing secret-bearing or untrusted values to flow into logs, traces, or prompts by default
- Building a separate sidecar context graph that can drift from compiler and runtime semantics
- Encoding retries, rollbacks, and kill switches only as framework convention
- Sacrificing interoperability for purity

## Bottom Line

If this language is meant to win, it should not just be "AI-friendly."

It should be:

- One language across frontend, backend, jobs, agents, and eventually mobile
- One type system and schema system everywhere
- One capability and verification model everywhere
- One tooling model for humans and AI systems
- Multiple runtimes and compilation targets underneath
- Strong enough interoperability that specialized runtimes can stay behind typed boundaries instead of blocking adoption

The strongest version of this idea is a language that treats application logic, UI state, workflows, schemas, model interactions, evals, and permissions as part of one coherent system rather than as separate stacks glued together by conventions.
