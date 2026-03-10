# CP-012 Build One Repo-Level Clasp Control-Plane Demo That Drives A Real Agent Loop

## Goal

Build one repo-level Clasp control-plane demo that drives a real agent loop.

## Why

The agent platform only becomes real when permissions, commands, hooks, agents, and policies are first-class declarations. This task belongs to the Control Plane Declarations track.

## Scope

- Add one checked-in demo under `examples/control-plane-demo/` that exercises repo memory, one command, one policy surface, and one verifier rule from one source of truth.
- The demo loop should be bounded and local: command selection, policy check, verifier execution, and trace output. It does not need to call a real external model or remote tool.
- Reuse the declaration families assumed to exist after `CP-001` through `CP-011`; do not invent new control-plane declaration categories in this task.
- Add or update regression coverage for manifest projection, human-readable projection, and one allowed-versus-denied action path in the demo.
- Update docs or examples only where the new surface changes visible behavior.
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/Clasp/Compiler.hs`
- `src/Clasp/Emit/JavaScript.hs`
- `examples/control-plane-demo/`
- `runtime/`
- `scripts/`
- `test/Main.hs`
- `docs/clasp-project-plan.md`

## Dependencies

- `CP-011`

Assume earlier `CP` tasks have already landed declaration syntax, generated projections, policy enforcement, and trace plumbing.

## Acceptance

- A checked-in demo exists at `examples/control-plane-demo/`.
- The demo projects machine-readable control-plane output and one human-readable projection from the same declarations.
- The demo includes one allowed command path and one denied or gated path under declared policy.
- Tests or regressions cover the generated projection and the allowed-versus-denied behavior.
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
