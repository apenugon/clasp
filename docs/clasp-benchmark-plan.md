# Clasp Benchmark Plan

## Goal

`Clasp` should be judged by whether it improves real software delivery by AI coding agents, not by whether it merely looks elegant on paper.

The core benchmark question is:

How much does using `Clasp` improve end-to-end performance for existing agent harnesses such as `Codex` and `Claude Code` on realistic software tasks?

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

### Workflow durability rate

How often long-running workflows survive:

- retries
- process restarts
- partial failures
- invalid external responses

without human repair.

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

### Suite D: Durable workflow tasks

Tasks that stress long-running correctness:

- resume after restart
- retry after partial failure
- maintain idempotency
- migrate persisted state
- recover from invalid queued data

### Suite E: Bug-fix tasks

Tasks seeded with realistic defects:

- type mismatches
- schema drift
- invalid boundary assumptions
- replay bugs
- stale workflow state bugs

These are often more informative than greenfield feature tasks.

## Benchmark Scenarios

Each scenario should define:

- repository starting state
- task prompt
- acceptance tests
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

If a feature is theoretically elegant but harms harness-level performance, that should count against it.

## Target Claims for Clasp

Over time, `Clasp` should aim to demonstrate:

- higher intervention-free completion rates than baseline languages on full-stack AI-heavy tasks
- lower total token cost for completing the same task
- higher compile-time catch rates for cross-layer contract mistakes
- better recovery from invalid LLM/tool outputs
- better durability for long-running workflows
- more shared definitions across frontend, backend, and agent systems

## Immediate Next Step

The first benchmark implementation should be simple:

1. Pick `Codex` and `Claude Code` as the primary harnesses.
2. Build a small but realistic benchmark repo in `TypeScript`.
3. Mirror the same benchmark scenarios in early `Clasp` as the language matures.
4. Record intervention count, tokens, time-to-green, and compile-time catches.
5. Expand into workflow and LLM boundary tests as soon as schemas and validation land.

The point is to start measuring early, even before `Clasp` is feature-complete.
