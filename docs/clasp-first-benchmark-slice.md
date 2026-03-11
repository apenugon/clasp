# First Credible Benchmark Slice

## Target

The nearest credible benchmark for `Clasp` is a benchmark-ready lead-inbox SaaS slice.

This is the closest target that is both:

- materially more realistic than the current schema-propagation benchmark
- still near enough to the current compiler/runtime foundation to build in focused steps

## Why This Slice

The existing repo already has the beginnings of this domain:

- shared lead records
- a typed route
- an AI-shaped foreign boundary
- a Bun-backed runtime path

The next benchmark should stay in that domain and make it more product-shaped rather than inventing a new app from scratch.

## Product Shape

The benchmark slice should model a small lead inbox with:

- lead intake through a typed route
- shared lead domain types used on both server and client-facing code
- generated validation at request and model boundaries
- in-memory state for stored leads
- a host-rendered inbox consumer or generated-client consumer
- one AI-shaped summary/prioritization boundary

This is still intentionally below the full long-term product scope. It does not need:

- auth
- durable workflows
- control-plane declarations
- SQLite persistence
- self-hosting
- native backend support

## First Benchmark Tasks

The first public benchmark tasks on this slice should look like product work, not compiler exercises.

Good first tasks:

1. Add a new lead field such as `segment` across intake, storage, inbox rendering, and model output validation.
2. Add a review state or inbox badge that changes server behavior and client rendering from one shared contract.
3. Tighten a boundary rule so invalid model output or invalid request data is rejected while preserving the happy path.

These tasks force cross-layer changes while staying small enough for repeated harness runs.

## Minimum Technical Floor

This slice needs a short critical path of language and runtime features:

- list support for inbox-style payloads and stored lead collections
- route-client generation so the client-side consumer shares the same route surface
- a small browser/client runtime helper for generated clients
- a concrete lead-inbox app scaffold with in-memory state and one AI boundary
- mirrored benchmark repos and prompts for `Clasp` and `TypeScript`

It does not require waiting for the full schema/control-plane/workflow roadmap.

## Swarm Critical Path

The focused swarm wave for this benchmark should execute these tasks in order:

- `FB-001` Add list types, literals, and JSON-boundary support for inbox-style payloads.
- `FB-002` Generate typed JavaScript route clients from route declarations.
- `FB-003` Add a browser/client runtime helper for generated route clients.
- `FB-004` Define the lead-inbox benchmark slice and mirrored repo contract.
- `FB-005` Build the Clasp lead-inbox server slice with in-memory state and one AI boundary.
- `FB-006` Add a host-rendered inbox consumer driven by generated route clients.
- `FB-007` Add mirrored benchmark tasks and prompts for the lead-inbox slice.

## Success Criteria

This benchmark becomes credible when:

- the same lead-inbox tasks run against mirrored `Clasp` and `TypeScript` repos
- the tasks cross server logic, shared contracts, validation boundaries, and client-visible behavior
- the benchmark harness can measure intervention-free completion, token cost, repair loops, and time-to-green
- the story is clearly closer to a real product change than to a toy schema patch
