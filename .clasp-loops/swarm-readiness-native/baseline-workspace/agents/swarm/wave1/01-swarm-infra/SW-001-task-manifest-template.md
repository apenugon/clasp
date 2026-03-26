# SW-001 Task Manifest Template

## Goal

Add a canonical swarm task template and a machine-readable task manifest schema so every worktree task uses the same fields.

## Why

The current task files vary in structure. The swarm needs stable task metadata for better dispatch, reporting, and future dependency handling.

## Scope

- Add a canonical markdown task template
- Add a JSON schema for machine-readable task metadata
- Document the required fields for new swarm tasks
- Update the swarm README to point to the template and schema

## Likely Files

- `agents/swarm/README.md`
- `agents/swarm/task-template.md`
- `agents/swarm/task.schema.json`
- `docs/clasp-project-plan.md`

## Dependencies

- None

## Acceptance

- New swarm tasks can be written against one documented template
- A task schema exists in the repo
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
