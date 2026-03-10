# Clasp Benchmark Snapshot v0.01

This document captures the first public benchmark snapshot referenced from the `v0.01` README.

## Context

- Harness: `Codex`
- Model: `gpt-5.4`
- Task family: shared schema change across a typed HTTP boundary and mock LLM/model boundary
- Constraint: zero human intervention

The benchmark workspace was made self-describing before this run so the agent did not need to inspect the parent compiler/docs just to learn task-local Clasp syntax.

## Latest One-Run Comparison

| Task | Duration | Total Tokens | Uncached Tokens | Result |
| --- | ---: | ---: | ---: | --- |
| `clasp-lead-priority` | `33.245s` | `76,023` | `8,183` | pass |
| `ts-lead-priority` | `35.587s` | `65,620` | `10,324` | pass |

Observed on this run:

- `Clasp` was `6.6%` faster
- `Clasp` used `20.7%` fewer uncached tokens
- `Clasp` used more total tokens because cached context was larger

## Caveat

This is an encouraging early signal, not a broad claim that `Clasp` is already better than TypeScript in general.

It is:

- one task family
- one harness
- one model
- one run

The point of publishing it is to show that the language hypothesis is measurable, not settled.
