# SW-003 Prompt And Merge Gate Hardening

## Goal

Harden the builder/verifier prompt path and merge gate so large prompts and shell interpolation regressions do not recur.

## Why

The first autopilot failed on prompt size, shell interpolation, and missing final merge semantics. This needs direct regression coverage.

## Scope

- Add tests or checks for prompt-file based handoff
- Ensure verifier prompts stay shell-literal-safe
- Ensure merge-gate failure paths produce structured reports
- Ensure final verification runs before integration

## Likely Files

- `scripts/clasp-builder.sh`
- `scripts/clasp-verifier.sh`
- `scripts/clasp-swarm-lane.sh`
- `scripts/test-swarm-control.sh`

## Dependencies

- `SW-002`

## Acceptance

- Prompt handoff remains file-based and shell-safe
- Merge-gate failures are reported cleanly
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
