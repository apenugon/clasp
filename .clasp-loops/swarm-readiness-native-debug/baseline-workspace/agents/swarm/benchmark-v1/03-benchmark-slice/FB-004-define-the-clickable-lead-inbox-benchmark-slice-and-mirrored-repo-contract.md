# FB-004 Define The Clickable Lead-Inbox Benchmark Slice And Mirrored Repo Contract

## Goal

Define the clickable lead-inbox benchmark slice and mirrored repo contract.

## Why

The swarm needs a concrete benchmark target, not just a generic SaaS aspiration. The first credible benchmark should stay close to the existing lead-summary domain and become a real browser-runnable vertical slice.

## Scope

- Define the exact lead-inbox slice that will be mirrored in `Clasp` and `TypeScript`.
- Specify the shared domain objects, routes, HTML pages, click-through flows, AI boundary, and the first benchmark task prompts.
- Require the slice to boot locally into a browser-runnable app that a human can click through.
- Keep the first version intentionally database-free and below control-plane or workflow complexity.
- Update benchmark docs or task-planning docs so the target is reproducible and easy for follow-on tasks to reference.
- Avoid implementing the full app in this task.

## Likely Files

- `docs/clasp-first-benchmark-slice.md`
- `docs/clasp-benchmark-plan.md`
- `docs/clasp-project-plan.md`
- `benchmarks/`
- `examples/`

## Dependencies

None.

## Acceptance

- The repo contains a concrete written definition of the first benchmark-ready clickable lead-inbox slice.
- The mirrored `Clasp` and `TypeScript` repo contract is explicit enough for follow-on implementation tasks.
- The first benchmark task prompts are sketched at product-feature level rather than only compiler-feature level.
- `bash scripts/verify-all.sh` passes.

## Verification

```sh
bash scripts/verify-all.sh
```
