# 0014 Best AI-Agent Language Swarm

## Goal

Drive Clasp toward being the best language for AI agents to build software and to build agent systems.

This is a broad goal-manager objective. Do not try to solve it as one large patch. Plan bounded, verifier-gated work that improves the language, runtime, compiler, and benchmarks in coherent stages.

## North Star

Clasp should let agents work at a semantic level instead of raw text and shell glue:

- agent loops, swarms, planners, verifiers, and workflows are ordinary Clasp programs
- app-building surfaces are typed, inspectable, and easy for agents to modify
- semantic artifacts expose context, dependencies, authority, verification, and user-visible behavior
- edits are fast enough that autonomous agents can iterate without spending most of their budget waiting
- verification is scenario-level, durable, and machine-readable

## Staged Priorities

1. Iteration-speed foundation
   - Preserve the recently landed promoted module-summary and edited-module validation wins.
   - Improve remaining cold/warm compiler-edit latency where it blocks autonomous work.
   - Do not regress `scripts/test-selfhost.sh` or the `src/Main.clasp` self-host check path.

2. Semantic artifacts for agents
   - Add or improve context graphs, dependency graphs, surface summaries, proof/verification traces, and machine-readable compiler outputs.
   - Prefer artifacts that directly help agents plan safe edits and understand behavior.

3. Agent workflow APIs
   - Improve typed planner/builder/verifier APIs, mailbox/memory surfaces, task DAG handling, durable progress, and retry/recovery semantics.
   - Keep loops and swarms as ordinary Clasp programs, not special compiler subcommands.

4. App-building surfaces
   - Improve typed routes, storage, workflows, forms/pages, tests, host interop, and packaging enough for agents to build real apps in Clasp.
   - Prefer changes that are useful in benchmark app tasks, not demo-only APIs.

5. Ergonomics
   - Improve diagnostics, fix hints, formatting, module/package clarity, record/state ergonomics, refactors, and polymorphic collection usability.
   - Target pain points visible in real Clasp programs, especially the compiler and swarm manager.

6. Benchmarks and proof
   - Add or strengthen benchmark tasks proving Clasp agents outperform raw TypeScript/shell workflows on software-building tasks.
   - Include verifier gates that would catch shallow/demo-only progress.

## Planning Rules

- Plan small, bounded task branches with explicit dependencies.
- Prefer independent complementary tasks when safe, but avoid concurrent writes to the same compiler/runtime hot files.
- Do not duplicate the just-finished edited-module speed task unless a follow-up is specifically needed.
- Every implementation branch must add or update focused tests.
- Reserve `bash scripts/verify-all.sh` for sign-off and integration closure.
- A verifier must fail if a task only adds docs or scaffolding without executable behavior or meaningful checks.

## Acceptance

- The goal manager can complete a wave with concrete improvements and verifier-backed evidence.
- `bash scripts/verify-all.sh` passes before final sign-off.
- The final verifier can honestly explain what got closer to the north star and what remains.
