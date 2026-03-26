# FB-004 Define The Lead-Inbox Benchmark Slice And Mirrored Repo Contract

## Goal

Define the lead-inbox benchmark slice and mirrored repo contract.

## Why

The swarm needs a concrete benchmark target, not just a generic SaaS aspiration. The first credible benchmark should stay close to the existing lead-summary domain and become more product-shaped.

## Scope

- Define the exact lead-inbox slice that will be mirrored in `Clasp` and `TypeScript`.
- Specify the shared domain objects, routes, AI boundary, host-rendered client consumer, and the first benchmark task prompts.
- Keep the first version intentionally database-free and below control-plane/workflow complexity.
- Update benchmark docs or task-planning docs so the target is reproducible and easy for future tasks to reference.
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

- The repo contains a concrete written definition of the first benchmark-ready lead-inbox slice.
- The mirrored `Clasp` and `TypeScript` repo contract is explicit enough for follow-on implementation tasks.
- The first benchmark task prompts are sketched at product-feature level rather than only compiler-feature level.
- `bash scripts/verify-all.sh` passes.

## Verification

```sh
bash scripts/verify-all.sh
```
