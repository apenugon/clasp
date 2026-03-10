# Clasp Swarm

This directory contains the worktree-based swarm backlogs.

Each lane is:

- a sequence of small task files
- processed in order
- backed by one branch per task
- executed in one dedicated Git worktree per active task

The swarm integration model is:

1. A lane agent creates a task branch from `agents/swarm-trunk`
2. The builder subagent edits in that branch's worktree
3. The verifier checks the task branch against a clean baseline worktree
4. The merge gate rebases the task branch onto the latest `agents/swarm-trunk`
5. Final verification runs again
6. The task commit fast-forwards `agents/swarm-trunk`

Wave directories:

- `full/`: full materialized project backlog and the default swarm target
- `wave1/`: initial swarm-infrastructure and core-language slices

Canonical task metadata:

- Start new task files from [`task-template.md`](./task-template.md).
- Validate machine-readable task manifests against [`task.schema.json`](./task.schema.json).
- In JSON manifests, `dependencies` is always an array of upstream task IDs; use `[]` when there are no dependencies.

Supervisor status surface:

- Run `scripts/clasp-swarm-status.sh [wave]` for the human-oriented lane and summary view.
- Run `scripts/clasp-swarm-status.sh --json [wave]` for machine-readable lane status plus aggregate run-state counts.
