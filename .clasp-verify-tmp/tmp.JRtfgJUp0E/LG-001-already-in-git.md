# LG-001 Already in git

## Goal

Prove the swarm skips tasks already recorded in trusted git history.

## Why

Completion should not depend only on marker files when the task already landed on main.

## Scope

- Skip already-landed tasks during ready-task selection

## Likely Files

- `scripts/clasp-swarm-common.sh`

## Dependencies

- None

## Acceptance

- done

## Verification

```sh
bash scripts/verify-all.sh
```
