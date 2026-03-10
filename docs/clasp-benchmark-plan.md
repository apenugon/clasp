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

## Benchmark Scenarios

Each scenario should define:

- repository starting state
- task prompt
- domain model and affected business objects
- feedback signal or operational trigger when relevant
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
- Does this reduce failures at trust boundaries?
- Does this make external-objective-driven changes more direct and auditable?
- Does this improve least-privilege enforcement and secret containment?
- Does this improve recovery under partial failure without increasing unsafe behavior?

If a feature is theoretically elegant but harms harness-level performance, that should count against it.

## Target Claims for Clasp

Over time, `Clasp` should aim to demonstrate:

- higher intervention-free completion rates than baseline languages on full-stack AI-heavy tasks
- lower total token cost for completing the same task
- higher compile-time catch rates for cross-layer contract mistakes
- better recovery from invalid LLM/tool outputs
- better durability for long-running workflows
- more shared definitions across frontend, backend, and agent systems
- stronger control-plane leverage with fewer sidecar conventions
- better traceability from external signals to the declarations that implement product behavior
- stronger privilege containment and lower secret-leak risk
- safer degraded-mode behavior under model, tool, or provider failure

## Immediate Next Step

The first benchmark implementation should be simple:

1. Pick `Codex` and `Claude Code` as the primary harnesses.
2. Build a small but realistic benchmark repo in `TypeScript`.
3. Mirror the same benchmark scenarios in early `Clasp` as the language matures.
4. Record intervention count, tokens, time-to-green, and compile-time catches.
5. Expand into workflow, control-plane, and LLM boundary tests as soon as schemas and validation land.
6. Add external-objective adaptation scenarios once the language can express typed feedback, goals, and rollout gates.

The point is to start measuring early, even before `Clasp` is feature-complete.
