# SW-004 Machine Readable Lane Status

## Goal

Add machine-readable status output for the swarm lanes.

## Why

Monitoring a real swarm should not depend on scraping human-oriented text.

## Scope

- Add a `--json` mode or equivalent machine-readable output to the swarm status script
- Include lane name, pid, current task, completed count, blocked count, and log path
- Keep the human-readable status mode intact

## Likely Files

- `scripts/clasp-swarm-status.sh`
- `scripts/test-swarm-control.sh`
- `agents/swarm/README.md`

## Dependencies

- `SW-002`

## Acceptance

- Swarm status can be consumed programmatically
- Human status output still works
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
