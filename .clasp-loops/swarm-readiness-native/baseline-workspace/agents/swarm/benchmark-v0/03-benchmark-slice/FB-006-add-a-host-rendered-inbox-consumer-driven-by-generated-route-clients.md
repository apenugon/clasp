# FB-006 Add A Host-Rendered Inbox Consumer Driven By Generated Route Clients

## Goal

Add a host-rendered inbox consumer driven by generated route clients.

## Why

The first credible benchmark should include client-visible product behavior without waiting for a full Clasp-native frontend framework.

## Scope

- Add a small host-rendered inbox consumer that calls into the generated route-client surface.
- Keep the consumer minimal and benchmark-oriented: rendering a lead inbox view and reflecting one shared contract change is enough.
- Reuse the generated client/runtime helper path instead of hand-writing endpoint glue.
- Add or update regression coverage for one client-visible path.
- Avoid introducing a large UI framework or app shell.

## Likely Files

- `examples/`
- `runtime/`
- `benchmarks/`
- `test/`

## Dependencies

- `FB-003`
- `FB-005`

## Acceptance

- A host-rendered inbox consumer exists and is driven by generated route clients.
- One client-visible product path is covered by tests or regressions.
- `bash scripts/verify-all.sh` passes.

## Verification

```sh
bash scripts/verify-all.sh
```
