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

The benchmark slice should model a small lead inbox that a human can open in a browser and click through locally.

It should include:

- a server-rendered HTML intake form for creating leads
- a server-rendered inbox page that lists stored leads
- at least one clickable lead detail or review page
- shared lead domain types used across server logic, HTML views, and AI-boundary code
- generated validation at request and model boundaries
- in-memory state for stored leads
- one AI-shaped summary/prioritization boundary

For the first benchmark, frontend credibility comes from real pages and click-through behavior, not from introducing a large SPA framework.

It is important to separate:

- the canonical runnable slice used as the reference implementation for each language
- the mirrored benchmark starting repos prepared for individual benchmark tasks

The canonical slice should boot and click through cleanly. The benchmark task repos derived from it should remain intentionally incomplete, so the harness still has real product work to do.

The implementation should be `SSR-first`, not `SSR-only`. The first HTML/page layer should remain compiler-known so later versions can:

- decide what stays on the server
- decide what can run on the client
- add reactive client islands or hydration boundaries
- keep using full host-JavaScript capabilities behind typed boundaries

The safe default renderer should emit inert SSR HTML, not arbitrary active content. Inline event handlers, raw `<script>` tags, and similar executable output should only arrive later through an explicit client-module, island, or clearly marked unsafe escape hatch.

The same rule should apply to styling. The first benchmark does not need a full design-system runtime, but it should avoid making raw `class` or raw `style` strings the default semantic model for UI styling. If host styling escapes are needed, they should be explicit and clearly outside the compiler-owned default path.

This is still intentionally below the full long-term product scope. It does not need:

- auth
- durable workflows
- control-plane declarations
- SQLite persistence
- self-hosting
- native backend support
- a client-side framework

## First Benchmark Tasks

The first public benchmark tasks on this slice should look like product work, not compiler exercises.

Good first tasks:

1. Add a new lead field such as `segment` across the intake form, storage, inbox page, detail page, and model output validation.
2. Add a review state or inbox badge that changes server behavior and page rendering from one shared contract.
3. Tighten a boundary rule so invalid model output or invalid form input is rejected while preserving the happy path.

These tasks force cross-layer changes while staying small enough for repeated harness runs.

The benchmark should therefore measure agents applying those changes to starting repos, not agents “building the whole app from nothing” and not a swarm pre-solving the exact prompt in advance.

The lead-inbox benchmark should also be maintained in two official modes:

- `Raw Repo`: the harness gets the normal task prompt and repo docs, but no exact file hints.
- `File-Hinted`: the harness gets the same task plus the analogous starting files for each language variant, so discovery is not the main differentiator.

Those runs should be compared separately rather than merged into one score, because they answer different questions about where `Clasp` is helping.

## Minimum Technical Floor

This slice needs a short critical path of language and runtime features:

- list support for inbox-style payloads and stored lead collections
- a compiler-known view/page surface that lowers into a dedicated rendering model rather than opaque foreign HTML helpers
- a compiler-known styling path, or at minimum an explicit rule that raw host class/style strings are escape hatches rather than the default page API
- SSR-first page/runtime support for returning safe HTML and handling form-style GET/POST flows
- enough placement or capability structure that later compiler passes can reason about server-only, client-only, or island-style behavior
- a concrete lead-inbox app scaffold with in-memory state, HTML pages, and one AI boundary
- mirrored canonical baselines plus intentionally incomplete benchmark repos and prompts for `Clasp` and `TypeScript`

It does not require waiting for the full schema/control-plane/workflow roadmap.

## Swarm Critical Path

The focused swarm wave for this benchmark should execute these tasks in order:

- `FB-001` Add list types, literals, and JSON-boundary support for inbox-style payloads.
- `FB-002` Add compiler-known view/page primitives and lowering for SSR-first rendering.
- `FB-003` Add runtime support for page responses, form actions, and future client/server placement.
- `FB-004` Define the clickable lead-inbox benchmark slice and mirrored repo contract.
- `FB-005` Build the Clasp lead-inbox app with compiler-owned pages, server-rendered inbox/detail/intake flows, and one AI boundary.
- `FB-006` Build the mirrored TypeScript lead-inbox baseline with the same click-through flows.
- `FB-007` Derive mirrored intentionally incomplete benchmark tasks and prompts for the clickable lead-inbox slice.

## Success Criteria

This benchmark becomes credible when:

- the same lead-inbox tasks run against mirrored `Clasp` and `TypeScript` repos
- those task repos are derived from runnable canonical baselines but are intentionally incomplete at task start
- both repos boot into a browser-runnable app that a human can click through locally
- the tasks cross frontend templates, backend logic, shared contracts, validation boundaries, and client-visible behavior
- the `Clasp` rendering and styling model remains compiler-owned enough to support later SSR/CSR placement, reactive client behavior, and style lowering while keeping safe SSR as the default page-rendering mode
- the benchmark harness can measure intervention-free completion, token cost, repair loops, and time-to-green
- the benchmark harness can report both `Raw Repo` and `File-Hinted` results for the same mirrored task family without changing the acceptance surface
- the story is clearly closer to a real product change than to a toy schema patch

For the next near-term improvement cycle, the benchmark should also become easier for `Clasp` agents specifically in these concrete ways:

- the `Clasp` task should not require inspecting generated JavaScript to understand boundary behavior
- the `Clasp` task should not require editing benchmark-only test scaffolding to complete an app-level product change
- request and model-boundary failures should already be shaped by compiler-owned/runtime-generated semantics rather than handwritten wrapper normalization
- task preparation should emit machine-readable semantic context for affected pages, forms, schemas, routes, and foreign bindings
