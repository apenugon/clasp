# Autonomous Swarm Runtime Requirements

This document captures the concrete Clasp features needed to run a native, self-hosted swarm that can improve Clasp itself and compete on AppBench-class workloads.

## Goal

Run a swarm entirely through native `claspc` and the native runtime, with:

- no Haskell in the execution loop
- no Node/Bun/JS server-side helpers
- one native runtime
- one native `claspc`
- one evented control plane that can plan, code, verify, review, benchmark, and merge bounded work

## System Shape

The intended architecture is:

- `manager`
  - owns task DAGs, leases, budgets, priorities, approvals, and stop conditions
- `planner`
  - decomposes goals into bounded tasks with explicit inputs and success criteria
- `coder`
  - edits code in isolated workspaces
- `reviewer`
  - checks correctness, regressions, and design alignment
- `verifier`
  - runs focused checks and scenario-level verification
- `optimizer`
  - generates competing variants and benchmark-oriented improvements
- `integrator`
  - selects winners, merges, requeues failures, and records outcomes
- `memory`
  - stores prior failures, benchmark deltas, design constraints, and reusable artifacts

External users should talk only to the `manager`, via:

- `claspc swarm ...`
- a native HTTP control plane
- an optional browser UI backed by that control plane

## Required Native Runtime Features

### 1. Event Log

The swarm needs a native append-only event log for:

- task creation
- lease acquisition/release
- worker heartbeat
- patch publication
- verification pass/fail
- benchmark deltas
- merge decisions
- approvals and escalations

Requirements:

- durable on local disk first
- ordered and replayable
- stable IDs for tasks, runs, agents, and artifacts

### 2. State Store

The runtime needs a native structured state store derived from the event log:

- task DAG
- agent leases
- retry counters
- active budgets
- artifact references
- approvals
- benchmark score history

SQLite is the practical first implementation, and the repo now has that as the first-class `claspc swarm` store.

### 3. Artifact Store

Large outputs should not be passed around as prompt text.

The runtime needs native artifact storage for:

- diffs
- logs
- benchmark traces
- compiled outputs
- screenshots
- review reports

Artifacts should be addressable by ID and referenced from task state.

### 4. Lease / Heartbeat Model

Agents must not own work forever.

The runtime needs:

- task leases
- lease expiry
- worker heartbeat
- dead-worker reaping
- retry scheduling
- bounded retry policy

### 5. Native Workflow / Supervisor Runtime

The swarm is fundamentally a workflow system.

The native runtime needs:

- durable workflow execution
- supervisor trees
- restart policies
- mailbox / event dispatch
- bounded child spawning
- safe stop / resume
- state handoff and upgrade-safe transitions

### 6. Native Tool Execution

Agents need controlled execution of tools and compilers.

The runtime needs:

- process spawning
- stdout/stderr capture
- timeouts
- environment control
- working-directory control
- exit-status capture
- policy-gated filesystem/network/process permissions

The repo now has the first native slice of this through `claspc swarm tool ...` and `claspc swarm verifier run ...`, with durable run records and artifact capture.

### 7. Native Merge / Review Gates

The runtime needs first-class support for:

- verifier surfaces
- merge gates
- approval gates
- policy-backed escalation
- merge decision recording

The repo now has the first native mergegate slice through `claspc swarm mergegate decide ...`, backed by stored verifier runs.

### 8. Native Route / Control-Plane Runtime

The swarm needs a server-side control plane implemented natively, including:

- run creation
- run status
- event streaming
- approval endpoints
- stop / resume / reprioritize
- artifact retrieval

The repo now has the first manager-facing native slice here through:

- `claspc swarm start|status|history|tasks|summary|tail`
- `claspc swarm stop|resume`
- `claspc swarm runs|artifacts`
- `claspc swarm approve|approvals`
- `claspc swarm policy set`
- `claspc swarm manager next`
- `claspc swarm objective create|status`
- `claspc swarm objectives`
- `claspc swarm task create`
- `claspc swarm ready`

That native slice now also includes:

- objective-scoped task count budgets
- task-scoped and objective-scoped run budgets
- persisted dependency edges for task DAGs
- task and objective deadlines
- task lease-timeout metadata
- dependency-aware ready-set projection
- lease-expiry-aware lease reacquisition checks
- persisted merge-policy requirements with approval/verifier state projection
- objective-driven manager next-action projection

## Required Compiler / Language Features

### 1. Whole-Project Native Build Ownership

`claspc` should decide frontend vs backend outputs automatically and build the whole project.

Needed compiler features:

- explicit whole-project build planning
- frontend/backend surface classification
- packaging of native backend binaries
- packaging of client-side JS assets only where frontend code exists

### 2. Fast Iterative Native Rebuilds

Swarm development requires fast rebuilds.

Needed compiler features:

- parallel project bundle construction
- parallel native image section work
- per-module native image caching
- persistent incremental compilation keyed by module dependency/interface fingerprints
- deterministic output after parallel work

### 3. Strong Native Surface Coverage

The self-hosted/native compiler must own these surfaces:

- routes
- workflows
- hooks
- tools
- tool servers
- guides
- policies
- agents
- verifiers
- merge gates

No backend semantics should depend on JS helper files.

### 4. Better Compiler-Authoring Ergonomics

The swarm will spend a lot of time writing compiler/runtime code in Clasp.

High-priority language improvements:

- multiline list and record literals
- trailing commas everywhere
- record destructuring / update
- collection helpers:
  - `map`
  - `fold`
  - `filter`
  - `find`
  - `any`
  - `all`
  - `concat`
- dictionary / map type
- clearer unsupported-surface diagnostics

### 5. Native Memory and Task APIs

The language/runtime surface should expose native operations for:

- event append/read
- task lookup/update
- artifact read/write
- lease acquire/renew/release
- benchmark result recording
- child worker spawn/reap

These should be Clasp-level primitives over the native runtime, not external shell glue.

The repo now has an ordinary-program slice of this through the internal `@swarm` runtime lane, which is wrapped by ordinary Clasp code in [`examples/swarm-native/Swarm.clasp`](/home/akul_medexfinance_com/clasp/examples/swarm-native/Swarm.clasp). That path lets Clasp programs create objectives/tasks, acquire and release leases, inspect ready/state projections, run tools/verifiers, inspect runs/artifacts, and drive approvals and merge decisions without shell wrapper scripts or external `claspc swarm ...` subprocesses. For the current supervised single-node swarm model, task creation plus durable tool/verifier execution is the native child-work substrate; higher-level memory retrieval and indexing remain follow-on control-plane work rather than a blocker for the ordinary-program orchestration loop.

## Required Safety / Governance Features

The swarm should be autonomous but bounded.

Required controls:

- explicit task budgets
- maximum spawn depth
- capability-based tool access
- policy-backed filesystem/network/process permissions
- approval-required actions for risky merges or broad writes
- audit trail for every merge decision

## Recommended Milestones

### Milestone 1: Single-Node Durable Kernel

Build:

- event log
- SQLite state store
- lease / heartbeat
- native workflow runtime
- `claspc swarm status|tail|stop|resume`

### Milestone 2: Native Task Workers

Build:

- native tool execution
- verifier / mergegate runtime surfaces
- artifact store
- coder/reviewer/verifier roles

### Milestone 3: Native Self-Improvement Loop

Build:

- planner + integrator roles
- benchmark ingestion
- patch + verify + benchmark + select loop
- memory retrieval from prior runs

### Milestone 4: AppBench-Oriented Optimizer

Build:

- benchmark-specific optimizer role
- competing candidate generation
- automated delta scoring
- performance regression memory

## Current Gaps

At the time of writing, Clasp is moving toward this shape but still lacks:

- full native workflow/supervisor/runtime parity
- durable native task/event storage
- native tool / verifier / mergegate surfaces end to end
- full backend surface parity without JS helpers
- rich incremental compilation at the module dependency level
- enough stdlib ergonomics for comfortable large-scale swarm authoring

## Success Condition

Clasp is ready to host an autonomous development swarm when all of the following are true:

- `claspc` is fully native and self-hosted
- backend execution is fully native
- the swarm manager/control plane runs natively
- worker roles persist and coordinate through native runtime state
- iterative rebuilds are fast enough for continuous self-improvement
- AppBench-style optimization loops can run without external orchestration glue
