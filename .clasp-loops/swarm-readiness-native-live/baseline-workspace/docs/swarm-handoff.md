# Swarm Handoff

This file is the shortest durable handoff for another agent picking up work on `Clasp`.

## Purpose

Use this document when:

- starting or restarting a swarm
- deciding whether a benchmark or docs change is allowed
- deciding what "done" means for a task or wave
- recovering context without chat history

## Current Objective

The current strategic goal is:

`finish the remaining backlog while making Clasp beat the frozen primary benchmark for the right reasons`

That means:

- improve the language, compiler, runtime, and semantic tooling
- do not keep tuning the benchmark to rescue Clasp
- make the agent fast path go through compiler-owned semantics instead of host glue, generated code archaeology, or brittle repo search

## Benchmark Policy

The benchmark hierarchy is:

- `Raw Repo`: primary benchmark and real scorecard
- `File-Hinted`: secondary diagnostic
- `Oracle`: control/research diagnostic

The primary benchmark is the frozen `Raw Repo` mode.

Rules:

- do not soften the benchmark to help Clasp
- do not add Clasp-only hints, prompt coaching, or scaffold edits to improve scores
- benchmark-side changes are only acceptable for neutral measurement/reporting or fairness protocol support
- the intended way to improve benchmark results is to improve Clasp itself

If a run loses because the agent still needs to reason about host glue, runtime wrappers, mutable scaffolding, or unresolved trust surfaces, that is a language/runtime issue to fix, not a benchmark issue to dodge.

## Swarm Policy

The default long-running wave is the canonical full backlog wave:

- [agents/swarm/full/README.md](/home/akul/DevProjects/synthspeak/agents/swarm/full/README.md)

Important invariants:

- start swarms from `main`
- `full` means "everything remaining", not "rerun old wins"
- globally completed tasks should be skipped automatically
- use the generated canonical task files under [agents/swarm/full](/home/akul/DevProjects/synthspeak/agents/swarm/full) as the source of truth

Useful commands:

```sh
bash scripts/clasp-swarm-status.sh full
bash scripts/clasp-swarm-summary.sh full
bash scripts/clasp-swarm-stop.sh full
bash scripts/clasp-swarm-start.sh full
```

## Definition Of Done

A task is not done because code exists in a worktree.

A task is done only when:

1. builder passes
2. verifier passes
3. the accepted snapshot passes `bash scripts/verify-all.sh`
4. the change lands back on `main`

If work is only present on a task branch or in swarm artifacts, it is not done.

## Testing Policy

The repository-wide minimum gate is:

```sh
bash scripts/verify-all.sh
```

Additional policy:

- runtime, boundary, interop, workflow, control-plane, and app-surface tasks should add scenario-level or end-to-end verification, not only narrow unit regressions
- benchmark-facing tasks should preserve the product task surface and avoid pushing edits into mutable test/runtime scaffolding unless that is the actual language/runtime bug being fixed
- once `SH-014` is complete, every newly integrated task should leave a committed feedback artifact under [agents/feedback](/home/akul/DevProjects/synthspeak/agents/feedback) so future agents can reuse concrete task lessons

## What Must Not Change Casually

Do not casually change:

- the frozen primary benchmark semantics
- benchmark prompts to advantage Clasp
- benchmark acceptance criteria to hide real language/runtime leaks
- the swarm rule that accepted work must land through `main`
- the requirement that new runtime/boundary/app-surface work add scenario/e2e coverage

## What To Optimize For

Clasp should make agents spend tokens only on genuinely open decisions.

That means preferring work that:

- closes mutable host/runtime surfaces
- strengthens compiler-owned boundaries
- improves semantic context, AIR, affected-surface planning, and propagation
- reduces ambient authority and unresolved trust
- keeps expensive verification selective and incremental

## If You Need More Context

Start here:

- [AGENTS.md](/home/akul/DevProjects/synthspeak/AGENTS.md)
- [docs/clasp-roadmap.md](/home/akul/DevProjects/synthspeak/docs/clasp-roadmap.md)
- [docs/clasp-project-plan.md](/home/akul/DevProjects/synthspeak/docs/clasp-project-plan.md)
- [docs/clasp-benchmark-plan.md](/home/akul/DevProjects/synthspeak/docs/clasp-benchmark-plan.md)
- [benchmarks/README.md](/home/akul/DevProjects/synthspeak/benchmarks/README.md)

If there is a conflict between ad hoc local convenience and the policies in this file, prefer this file.
