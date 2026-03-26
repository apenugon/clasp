# Autonomous Swarm Build Plan

This document records the full set of capabilities `Clasp` needs in order to host a native autonomous software swarm that can improve the language and attack `AppBench` directly without falling back to deprecated bootstrap, Bun, or Node runtime surfaces.

## Product Shape

The external product should be one system with two interfaces:

- a native `claspc swarm ...` CLI
- a native control-plane API and optional browser UI on top of it

Users should chat only with the manager agent. Every other agent remains an internal runtime actor unless explicitly surfaced for review or debugging.

## Swarm Architecture

The minimum viable swarm should be role-based, not peer-anarchic:

- `manager`: owns objectives, budgets, priorities, approvals, and stop conditions
- `planner`: decomposes objectives into bounded task DAGs
- `coder`: edits code in isolated worktrees
- `reviewer`: checks correctness, regressions, and architectural alignment
- `verifier`: runs focused tests and scenario checks
- `optimizer`: generates and scores benchmark-oriented variants
- `integrator`: lands accepted patches and requeues failed work
- `memory`: maintains reusable lessons, failures, and benchmark deltas

Self-replication should be bounded. New agents may only be spawned through manager-approved task manifests with explicit budgets, capability scopes, and maximum depth.

## Shared State Model

Prompt-pasting is not enough. Agents need native shared state with four layers:

1. `event log`
   - append-only, durable, auditable
   - task creation, lease changes, artifact publication, verification, benchmark deltas, approvals, merges

2. `task state store`
   - current lease owner
   - DAG dependencies
   - retries, budgets, deadlines
   - task-local hypotheses and status

3. `artifact store`
   - diffs
   - logs
   - screenshots
   - benchmark traces
   - compiled outputs

4. `memory index`
   - reusable architectural decisions
   - similar failure retrieval
   - file-level ownership history
   - best-known optimizations

The storage stack should start simple:

- append-only JSONL event logs for language-level prototyping
- SQLite-backed indexed state and memory for the real native control plane
- file-backed artifact blobs

## Native Runtime Features Needed

These belong in the one native runtime, not in JS helpers:

### Foundation

- append-only file output
- directory creation
- environment variable reads
- timestamps
- file existence and file reads
- path composition helpers

### Control Plane

- durable workflow execution
- supervisor trees and restart policy
- mailbox/event dispatch
- task leases and heartbeats
- cancellation and escalation
- approval gates

### Execution

- native tool execution
- bounded process spawning
- stdout/stderr capture
- timeouts
- exit-code capture
- sandbox hooks for future isolation

### State

- SQLite runtime bindings for task/event state
- append-only log helpers
- snapshot and replay support
- generation-safe hot-swap for long-running managers

### Benchmark Loop

- benchmark invocation as native runtime calls
- score capture and artifact retention
- side-by-side candidate comparison
- optimizer-side selection hooks

## Language And Compiler Features Needed

The swarm should be written mostly in `Clasp`, so the language must be pleasant for compiler and orchestrator work.

### Ergonomics

- multiline structured literals
- collection helpers: `map`, `fold`, `filter`, `flatMap`, `find`, `any`, `all`, `concat`
- a dictionary/map type
- record destructuring
- record update syntax
- better unsupported-surface diagnostics

### Runtime Surface Parity

The self-hosted native path still needs first-class support for:

- `workflow`
- `supervisor`
- `hook`
- `toolserver`
- `tool`
- `agent`
- `guide`
- `policy`
- `verifier`
- `mergegate`

### Whole-Project Build Planning

The self-hosted compiler needs to own:

- frontend/backend build partitioning
- whole-project compilation planning
- emitted client package generation
- native app packaging

## External User Interaction

The intended interaction model is:

- chat with the manager
- inspect task state, events, and artifacts
- approve or reject risky changes
- watch benchmark deltas
- stop, resume, or reprioritize objectives

The manager chat should be backed by real runtime state transitions, not prompt-only narration.

## What Is Implemented Now

The repo now has two swarm layers:

- a language-level native kernel example in [`examples/swarm-kernel/Main.clasp`](/home/akul_medexfinance_com/clasp/examples/swarm-kernel/Main.clasp)
- a first-class native CLI control plane in `claspc swarm ...`
- an ordinary-program Clasp wrapper over the durable swarm substrate in [`examples/swarm-native/Swarm.clasp`](/home/akul_medexfinance_com/clasp/examples/swarm-native/Swarm.clasp) and [`examples/swarm-native/Main.clasp`](/home/akul_medexfinance_com/clasp/examples/swarm-native/Main.clasp)

The implemented native primitives now include:

- `timeUnixMs : Int`
- `envVar : Str -> Result Str`
- `readFile : Str -> Result Str`
- `appendFile : Str -> Str -> Result Str`
- `mkdirAll : Str -> Result Str`
- SQLite-backed task/event state in the native launcher
- native artifact capture for tool and verifier runs
- native mergegate decisions over stored verifier runs

These are available through the self-hosted native compiler/runtime path and are exercised by the native example at [`examples/swarm-kernel/Main.clasp`](/home/akul_medexfinance_com/clasp/examples/swarm-kernel/Main.clasp).

That example proves:

- native manager-style state root creation
- append-only event logging
- environment-configured actor identity
- native timestamp capture
- per-task state projection from the event log
- per-task event history replay
- whole-log task snapshots for manager views
- direct native control-plane readouts for:
  - `status`
  - `history`
  - `tasks`
  - `summary`
- native task lifecycle transitions for:
  - create
  - lease
  - release
  - heartbeat
  - complete
  - fail
  - retry / requeue

The native `claspc swarm` control plane now also proves:

- durable SQLite-backed task state
- `claspc swarm start|status|history|tasks|summary|tail|runs|artifacts`
- native `claspc swarm stop|resume`
- native `claspc swarm approve|approvals`
- native `claspc swarm policy set`
- native `claspc swarm manager next`
- native `claspc swarm objective create|status`
- native `claspc swarm objectives`
- native `claspc swarm task create`
- native `claspc swarm ready`
- native `claspc swarm tool ...` execution with stdout/stderr artifacts
- native `claspc swarm verifier run ...`
- native `claspc swarm mergegate decide ...`
- objective-scoped task budgets
- task dependency edges and ready-set projection
- task/objective run-budget enforcement
- deadline-aware ready/lease gating
- lease-expiry-aware lease reacquisition rules
- persisted merge-policy state with approval/verifier tracking
- objective-driven next-action projection for the manager loop
- ordinary Clasp programs can drive the same substrate directly through `runCommandJson`'s internal `@swarm` runtime lane without shell wrapper scripts or external `claspc swarm ...` subprocesses
- the ordinary-program path can create objectives and tasks, acquire leases, run native tool and verifier commands, record approvals, decide merge gates, and inspect runs/artifacts/summary state from Clasp itself

## Remaining Expansion Work

The repo now has a supervised single-node ordinary-program path over the durable store. The remaining expansion work is:

1. Native workflow and supervision runtime.
2. Reusable memory retrieval and higher-level artifact indexing/search.
3. Manager chat and higher-level objective steering over the native control plane.
4. Benchmark-specialized optimizer loop for `AppBench`.

Deleting the remaining deprecated expectations only becomes safe once those runtime and compiler ownership boundaries are real.
