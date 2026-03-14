# Clasp Benchmark Plan

## Goal

`Clasp` should be judged by whether it improves real software delivery by AI coding agents, not by whether it merely looks elegant on paper.

The core benchmark question is:

How much does using `Clasp` improve end-to-end performance for existing agent harnesses such as `Codex` and `Claude Code` on realistic software tasks?

The most important concrete proving ground should become:

How much faster can an agent build and evolve a moderate SaaS application in `Clasp` than in a baseline stack?

## Primary Thesis

The strongest public claim for `Clasp` is not:

- "the syntax is shorter"

The stronger claim is:

- "agents using Clasp finish more tasks correctly, with fewer interventions, fewer repair loops, lower total token cost, and stronger safety guarantees"

This benchmark program should be designed to prove or falsify that claim.

## First Credible Benchmark

The first public benchmark likely to change minds should be a benchmark-ready moderate SaaS slice, not a toy repo.

It should:

- require coordinated product changes across frontend, backend, shared contracts, and validation boundaries
- boot into a browser-runnable app where a human can click through the core flow in both the `Clasp` and baseline variants
- keep the `Clasp` frontend on a compiler-owned view/page model so future SSR/CSR placement and client interactivity remain tractable
- keep the default `Clasp` SSR renderer safe and inert, with future client-side JavaScript introduced through explicit client modules, islands, or typed host interop rather than arbitrary raw script output
- include one AI/model or tool boundary that exercises typed untrusted input handling
- keep the schema model transport-neutral so later benchmark rounds can compare `JSON` and generated binary transports without redefining the app contracts
- emit machine-readable page/action or UI-flow artifacts where possible so agents are not forced to rely only on browser scraping
- prefer tasks that can later grow into constrained-value, state-transition, and storage-correctness benchmarks without changing the product surface entirely
- include at least one explicit interop edge to a host runtime, library, storage engine, or provider SDK
- ship against real tests and task acceptance criteria rather than hand-waved correctness
- run under `Codex` and `Claude Code` against mirrored `Clasp` and `TypeScript` repos, with `Python` variants where orchestration-heavy comparisons are useful

The key repo-shape rule for this first benchmark is:

- maintain canonical runnable baseline apps in each language
- derive intentionally incomplete task-starting repos from those baselines
- benchmark the agent on applying the requested product change, not on watching humans pre-complete the exact prompt

This is the first benchmark that can credibly demonstrate whether `Clasp` should become the default semantic layer for software-building agents.

## Benchmark Principles

### 1. Benchmark the harness, not just the language

The unit of measurement should usually be:

- agent harness
- model
- task
- language

The practical question is not whether `Clasp` is elegant in isolation. The practical question is whether an agent using a real harness performs better with `Clasp` than with a baseline language.

### 2. Optimize for total system efficiency

Measure:

- prompt tokens
- completion tokens
- retry tokens
- debugging tokens
- human intervention cost
- wall-clock time
- successful completion rate

Do not reduce the benchmark to source-file token count. That is too narrow and too easy to game.

Syntax-level experiments are still useful, but only when evaluated through end-to-end harness outcomes rather than token counts alone.

### 3. Favor realistic tasks over toy snippets

The benchmark suite should focus on tasks that require:

- changing multiple files
- crossing frontend/backend boundaries
- changing page rendering or click-through user flows
- interacting with schemas
- handling runtime boundaries
- working with LLM outputs and tools
- surviving failures and retries

The highest-value benchmark family should be built around a moderate SaaS app that exercises real product flows rather than isolated compiler or schema exercises.

### 4. Keep comparisons fair

Comparisons should hold constant:

- task description
- harness
- model
- budget
- time limit
- repository shape
- test suite

Only the language and framework baseline should vary.

For product-slice benchmarks, fairness also means:

- both language variants start from mirrored, intentionally incomplete task repos
- both variants are derived from runnable canonical baselines with the same visible flow
- neither side gets the exact benchmark change pre-applied
- the first clickable lead-inbox task family should stay mirrored around one small product change such as a lead segment threaded through intake, storage, rendering, and the model boundary
- acceptance tests should exercise the same app-owned server surface on both sides, so the `Clasp` variant does not require benchmark-only test/runtime edits for ordinary field propagation

The benchmark program should publish at least three official comparison modes instead of collapsing everything into one headline number:

- `Raw Repo`: normal task prompt plus the repo's ordinary docs and structure, with no exact entry-file hints beyond what a real user would provide. This mode measures the combined effect of language design, repo shape, compiler artifacts, and agent discovery cost.
- `File-Hinted`: the same task and acceptance criteria, but each language variant names the analogous entry files explicitly. This mode reduces repo-discovery noise so the comparison focuses more on propagation, editing, and verification behavior once the agent is on the right surfaces.
- `Oracle`: the same task and acceptance criteria, but each language variant names the exact analogous files expected to change for the benchmark prompt. This mode largely removes discovery variance and isolates the propagation, editing, and verification model once the agent is already on the right surface.

All three modes are useful, and they should be reported separately, but they are not equally important.

- `Raw Repo` is the primary benchmark and the main product scorecard. It is the closest to the real question: can the harness enter an unfamiliar codebase, understand it, bound the change, and ship it safely?
- `File-Hinted` is a secondary diagnostic benchmark that helps separate discovery effects from propagation and verification effects.
- `Oracle` is a control benchmark for research and analysis, not the headline benchmark.

A `Clasp` win in `Raw Repo` but not `File-Hinted` still matters, because discovery and environment understanding are part of the real product. A `Clasp` win in `Oracle` is useful for isolating edit-model behavior, but it should not be treated as the main public proof that the language is better for agents.

### 4A. Publication-grade fairness protocol

No benchmark is perfectly neutral in the abstract, but the benchmark program should define a strict comparison protocol that is hard to dismiss as accidental prompt shaping or repo favoritism.

That protocol should require:

- a frozen benchmark bundle containing the exact task repo snapshots, prompts, `AGENTS.md`, acceptance tests, harness wrapper, seed data, and commit hashes for both sides
- mirrored canonical baselines whose task repos are derived from the same visible product slice and acceptance contract
- equal information content across prompts and repo guidance, even when analogous file paths differ by language
- one identical acceptance surface per task family, with no language-specific runtime-wrapper or test-scaffold edits allowed as part of ordinary product changes
- randomized run order across language variants so cache or ordering effects are not always biased one way
- repeated runs with the same harness, model, budget, and time limit rather than one-shot anecdotal samples
- phase decomposition of each run into at least discovery, first edit, first verify, and time-to-green segments
- separate reporting for `Raw Repo`, `File-Hinted`, and `Oracle` rather than collapsing them into one number

Every published benchmark result should say explicitly which mode it uses and which frozen benchmark bundle it belongs to. Headline benchmark claims should default to `Raw Repo`, with the other modes presented as supporting analysis rather than replacements for the main scorecard.

### 5. Publish raw traces when possible

For persuasive public results, keep:

- prompts
- model versions
- harness versions
- commit hashes
- tool traces
- token counts
- test outputs
- intervention logs

`Clasp` should be auditable at the benchmark layer too.

### 6. Benchmark external-objective adaptation, not just file edits

The strongest long-term benchmark for `Clasp` is not merely:

- "can an agent patch the code?"

It is:

- "can an agent interpret typed external feedback, identify the affected domain objects and declarations, make a bounded change, and ship it safely?"

That means the benchmark suite should eventually include tasks driven by:

- conversion drops
- false-positive or false-negative business decisions
- support escalations
- latency or cost pressure on key user flows
- workflow failures tied to domain objects

The language should be judged partly on whether it makes that loop more direct and less error-prone.

### 7. Benchmark Clasp as the semantic layer, not as a purity contest

A strong result for `Clasp` does not require every line of the system to be written in `Clasp`.

What matters is whether `Clasp` can own:

- shared schemas and contracts
- trust-boundary validation
- backend and workflow logic
- generated clients and tool interfaces
- policy and agent-control semantics where they apply

while interoperating cleanly with:

- `JavaScript` or `TypeScript` packages
- native libraries or storage engines
- model-provider SDKs
- host UI runtimes

This is the more honest path to covering most software-building agent work, and it should be reflected in the benchmark suites.

### 8. Benchmark semantic artifacts against raw-text workflows

`Clasp` should not only be benchmarked as source code.

It should also be benchmarked as a supplier of machine-readable artifacts such as:

- context graphs
- UI/action graphs
- structured diagnostics
- semantic edit or refactor operations
- boundary manifests

Later benchmark rounds should compare:

- text-only and browser-scraping workflows
- semantic-artifact-assisted workflows

The benchmark harness should record the workflow-assistance variant explicitly in frozen bundles and result protocol metadata so the same repeated Clasp task series can be reported as `raw-text` versus `compiler-owned-air` planning rather than relying on note naming conventions or manifest filenames alone.

That is the honest way to test whether the language is actually reducing agent work rather than just moving complexity around.

### 9. Freeze the benchmark before using it as the standing scorecard

Once a benchmark family is good enough for language iteration, freeze:

- the task repo contents
- the prompt text
- the repo guidance files
- the acceptance commands
- the harness wrapper
- the reporting mode definitions

After that, improve the language and runtime, not the benchmark. New benchmark ideas should become new benchmark families or explicit protocol versions rather than silent edits to the standing scorecard.

## Headline Metrics

### Harness uplift

This should become the flagship metric.

Definition:

- The relative improvement of a given harness-model pair when using `Clasp` versus a baseline language on the same task suite.

Examples:

- success rate uplift
- intervention-free completion uplift
- token cost reduction
- time-to-green reduction

This is the clearest way to answer: "How much better does `Codex` or `Claude Code` perform when the project is written in Clasp?"

### App feature throughput

This should become the product-facing benchmark headline.

Definition:

- the rate at which a harness can add, modify, and safely ship real product features in the moderate SaaS dogfood app

This is the clearest answer to whether `Clasp` is actually a better medium for agent-built applications rather than only a nicer research compiler.

### Intervention-free completion rate

Percentage of tasks completed successfully without a human stepping in.

This is more valuable than simple eventual completion.

### Time to green

Elapsed time until:

- the task is implemented
- the test suite passes
- the result satisfies the task acceptance criteria

### Total token cost

Include:

- prompt tokens
- completion tokens
- retries
- failed attempts
- debugging loops

This should be measured at the task level, not just per file.

### Repair loop count

How many cycles of:

- edit
- compile
- test
- fix

are needed before success.

### Compile-time catch rate

How many defects are caught before runtime.

## Near-Term Win Plan

The immediate benchmark objective is not to "improve Clasp in general."

It is:

- beat the mirrored `TypeScript` baseline on the clickable `lead-segment` benchmark

The first `lead-segment` run showed that `Clasp` still forces the agent to reason about too much host and runtime machinery. The biggest near-term gaps are:

- the `Clasp` task can still require edits outside the intended app surface, especially runtime or harness-adjacent glue
- request-boundary and model-boundary failures are not fully compiler-owned end to end, so the agent may need to normalize error behavior in host code
- host runtime bindings remain too free-form, which makes foreign-boundary changes harder than they should be
- agents still lack a machine-readable semantic map of the benchmark app surface, so they fall back to reading generated output or grepping files
- compiler-emitted page metadata still leaks into the same HTML projection humans and tests read, which turns metadata details into benchmark noise
- benchmark seed fixtures and mock boundary behavior still live in imperative host code instead of compiler-owned fixture declarations or generated adapters

The near-term win condition for `Clasp` on this benchmark should be:

- the agent solves the mirrored `Clasp` task without inspecting generated JavaScript
- the agent does not patch benchmark test scaffolding or generic runtime wrapper code to satisfy expected boundary behavior
- the change stays mostly inside compiler-known app declarations plus clearly structured host binding data
- repeated runs show lower or comparable time-to-green and uncached token usage than the `TypeScript` baseline

That means the next focused implementation wave should prioritize:

- benchmark isomorphism and task-surface fairness
- compiler-owned request and model boundary behavior for page flows
- explicit separation between machine-readable page metadata and the default human SSR HTML projection
- structured host-binding manifests for foreign/runtime edges
- generated host-binding adapters plus compiler-owned seeded fixture surfaces for benchmark apps
- semantic context artifacts for page, route, schema, and binding relationships
- benchmark-prep semantic packs and acceptance helpers that keep ordinary product tasks out of runtime or test-only mutation surfaces
- repeated benchmark automation so the repo can measure whether those changes are actually improving the result

This is especially important for `Clasp`, because shared types and strong static semantics are part of the language value proposition.

### Boundary safety catch rate

How often invalid external data is rejected automatically at generated trust boundaries.

This should cover:

- HTTP payloads
- stored data
- queue payloads
- tool inputs/outputs
- LLM outputs

### Privilege containment rate

How often the system prevents a harness or workflow from performing side effects outside its declared authority.

This should cover:

- file writes outside allowed roots
- unauthorized network access
- unauthorized process execution
- secret access without declared capability
- tool invocations outside policy

### Workflow durability rate

How often long-running workflows survive:

- retries
- process restarts
- partial failures
- invalid external responses

without human repair.

### Degraded-mode success rate

How often the system continues safely under partial failure by using:

- fallback providers
- bounded retries
- degraded read-only or limited-function mode
- operator handoff
- rollback paths

### Schema drift resistance

How often a change in one layer causes a break in another, and whether the problem is caught at compile time or by generated boundary validation.

### Shared-definition ratio

How much of the project's data and contract surface is shared across:

- frontend
- backend
- workflows
- agents
- apps

This helps show whether `Clasp` actually delivers on "one language everywhere."

### Context-resolution efficiency

How effectively the harness can reach the minimum relevant context for a task or failure.

This should consider:

- how many files or declarations the harness had to inspect
- whether a compiler-emitted context graph reduced irrelevant scanning
- whether prompts and task context could be built from a smaller semantic neighborhood

This matters because a language that emits good context graphs should reduce wasted exploration, token spend, and repair-loop drift.

### External-objective traceability

How easily the system can map a runtime or market signal back to:

- affected business objects
- affected prompts and workflows
- affected routes, policies, and tests
- the declarations responsible for a given behavior

This is important because future agent systems will increasingly operate on external outcomes rather than on file trees.

### Goal-constrained adaptation rate

How often the harness can take a typed external signal, make a change, and satisfy explicit product guardrails such as:

- do not exceed a latency budget
- do not increase false rejects above a threshold
- do not exceed a token-spend limit
- do not violate a workflow safety policy

### Secret containment and redaction rate

How often secrets and sensitive values are kept out of:

- prompts
- traces
- logs
- error payloads
- unintended tool inputs

## Benchmark Harnesses

### Initial harness set

The first benchmark suite should target real tools people already use.

Primary harnesses:

- `Codex`
- `Claude Code`

Secondary harnesses:

- `Aider`
- self-hosted agent loops or research harnesses used by the team

The first public benchmark story should focus on `Codex` and `Claude Code`, because those results are easy to understand and directly relevant to likely early adopters.

## Baseline Languages

The first comparison set should be practical rather than exhaustive.

Primary baselines:

- `TypeScript` for full-stack and app-adjacent work
- `Python` for agent-heavy backends and orchestration code

Optional later baselines:

- `Kotlin` for strongly typed cross-platform application logic
- `Go` for service-oriented backend work

The initial target is not to beat every language on every axis. The target is to prove that `Clasp` produces a measurable harness-level advantage in the workflows it is designed for.

## Benchmark Suites

### Suite A: Authoring microbenchmarks

Short tasks designed to isolate language ergonomics for agents:

- add a function
- refactor a module
- change a shared type
- fix a compile error
- adapt to a changed schema
- compare compact syntax candidates against more verbose renderings of the same semantics

These are useful for fast iteration but should never be the only public benchmark.

These microbenchmarks should also compare:

- canonical compact source
- human-readable explain renderings
- machine-readable diagnostics versus prose diagnostics

The goal is to determine which forms actually improve harness performance rather than assuming that more or less verbosity is automatically better.

### Suite B: Full-stack feature tasks

Tasks that require coordinated changes across:

- frontend UI
- backend logic
- shared contracts
- validation boundaries

Example tasks:

- add a new form and API endpoint
- change an authenticated resource shape
- add a realtime event payload
- introduce a schema migration with UI and backend implications

### Suite C: LLM and tool-integration tasks

Tasks that stress typed AI interfaces:

- add structured model output handling
- define a new tool and wire it into an agent
- recover from invalid model output
- add a prompt-output contract and tests
- prevent prompt or tool injection from escalating authority
- preserve secret redaction through traces and tool calls

### Suite D: Durable workflow tasks

Tasks that stress long-running correctness:

- resume after restart
- retry after partial failure
- maintain idempotency
- migrate persisted state
- recover from invalid queued data
- survive provider outage with bounded degradation
- upgrade through a supervised hot-swap with explicit state migration
- drain old code versions while the new version warms up
- trigger rollback when upgrade health checks fail
- preserve mailbox or message-driven workflow semantics across upgrade boundaries
- trigger operator handoff or rollback safely

### Suite E: Bug-fix tasks

Tasks seeded with realistic defects:

- type mismatches
- schema drift
- invalid boundary assumptions
- replay bugs
- stale workflow state bugs

These are often more informative than greenfield feature tasks.

### Suite F: Agent control-plane tasks

Tasks that stress the operational layer around the code:

- add or change a repository instruction block
- tighten or relax a capability policy
- add a typed command or hook
- register a new external tool or provider
- fix a broken verifier or permission mismatch
- prevent an unauthorized side effect without blocking an allowed one
- tighten secret or data-retention policy without breaking execution

These tasks matter because current agent systems spend real effort in Markdown, JSON, shell, and settings files that are not part of the application language.

These tasks should also measure whether the harness can navigate through compiler-emitted context graphs rather than broad repository search.

### Suite G: External-objective adaptation tasks

Tasks that begin from product or market feedback instead of from code-local change requests:

- a lead-routing rule is harming enterprise conversion
- a support escalation reveals a bad refund or triage path
- an LLM classification is hurting a business KPI for a defined segment
- a token-cost spike requires a safe prompt or routing adjustment
- a workflow needs a guarded rollout based on explicit business constraints

These tasks should require the harness to:

- interpret the typed feedback signal
- identify affected business objects and declarations
- implement a bounded change
- validate it against tests, evals, and rollout guardrails

These tasks are especially good places to test objective-graph queries rather than file-oriented search behavior.

### Suite H: Mixed-stack semantic-layer tasks

Tasks where `Clasp` owns the system model while host-specific pieces remain in other runtimes:

- change a shared contract and preserve a `JS` UI bridge
- swap or upgrade a provider SDK behind a typed model/tool boundary
- adapt a storage or native helper boundary without leaking untyped behavior into app logic
- keep a benchmark repo credible by reusing a practical host runtime rather than reimplementing everything in `Clasp` first

These tasks matter because the real adoption path is not substrate purity. It is making `Clasp` the primary semantic layer of a mixed system.

### Suite I: Correctness and storage tasks

Tasks that stress whether `Clasp` can prove more of the app before runtime:

- add a constrained field and propagate it through forms, routes, storage, and model validation
- forbid an illegal business-object state transition and update affected pages and actions
- add a storage constraint or migration and keep query and mutation code correct
- tighten a transaction or mutation rule without leaking raw SQL or ambient side effects

These tasks matter because the strongest claim for `Clasp` is not just less glue. It is more compile-time and boundary-time correctness across the whole product stack.

## Benchmark Scenarios

Each scenario should define:

- repository starting state
- task prompt
- domain model and affected business objects
- feedback signal or operational trigger when relevant
- whether a context graph is available to the harness and in what form
- acceptance tests
- eval and rollout guardrails where relevant
- policy and security constraints
- budget limit
- time limit
- allowed tools
- success criteria

The same scenario should be runnable across all language baselines.

## Benchmark Outputs

Each run should record:

- harness name
- model name and version
- run date
- repository commit
- task identifier
- success or failure
- intervention count
- total tokens
- wall-clock time
- context-resolution path or graph-query artifacts when available
- compile/test failures
- generated trace artifacts

Public benchmark summaries should include both:

- aggregated scoreboards
- raw per-run data

## How Benchmarks Should Influence Language Design

The benchmark program should shape `Clasp`, not merely evaluate it after the fact.

Language and platform decisions should be judged against questions like:

- Does this feature improve intervention-free completion?
- Does this reduce total repair loops?
- Does this reduce total token spend?
- Does this improve compile-time defect detection?
- Does this improve detection of illegal state transitions, invariant violations, and storage mismatches?
- Does this reduce failures at trust boundaries?
- Does this make external-objective-driven changes more direct and auditable?
- Does this improve least-privilege enforcement and secret containment?
- Does this improve recovery under partial failure without increasing unsafe behavior?
- Does this reduce irrelevant repository scanning by making semantic context easier to resolve?

If a feature is theoretically elegant but harms harness-level performance, that should count against it.

## Target Claims for Clasp

Over time, `Clasp` should aim to demonstrate:

- higher intervention-free completion rates than baseline languages on full-stack AI-heavy tasks
- lower total token cost for completing the same task
- higher compile-time catch rates for cross-layer contract mistakes
- higher catch rates for illegal state transitions, constrained-value violations, and storage-schema drift
- better recovery from invalid LLM/tool outputs
- better durability for long-running workflows
- more shared definitions across frontend, backend, and agent systems
- stronger control-plane leverage with fewer sidecar conventions
- better traceability from external signals to the declarations that implement product behavior
- stronger privilege containment and lower secret-leak risk
- safer degraded-mode behavior under model, tool, or provider failure
- smaller, more relevant task context through compiler-emitted context graphs
- stronger performance as the primary semantic layer of a mixed-stack system, not just in all-Clasp toy environments

## Immediate Next Step

The first benchmark implementation should be simple:

1. Pick `Codex` and `Claude Code` as the primary harnesses.
2. Build a benchmark-ready moderate SaaS slice in `TypeScript` with shared contracts, frontend and backend changes, and one AI/tool boundary.
3. Mirror the same slice in early `Clasp`, allowing explicit interop edges where that keeps the comparison honest.
4. Define a small set of real product-change tasks rather than only schema microbenchmarks.
5. Record intervention count, tokens, time-to-green, compile-time catches, and context-resolution behavior.
6. Expand into workflow, control-plane, and LLM boundary tests as soon as schemas and validation land.
7. Add external-objective adaptation scenarios once the language can express typed feedback, goals, and rollout gates.

The point is to start measuring early, even before `Clasp` is feature-complete.
