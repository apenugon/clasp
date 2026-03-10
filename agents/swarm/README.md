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
4. The merge gate creates a fresh accepted-snapshot worktree from the latest `agents/swarm-trunk`
5. Only the verified workspace diff is applied into that accepted snapshot
6. Final verification runs again in the accepted snapshot before `agents/swarm-trunk` advances

Wave directories:

- `full/`: full materialized project backlog and the default swarm target
- `wave1/`: initial swarm-infrastructure and core-language slices

Canonical task metadata:

- Start new task files from [`task-template.md`](./task-template.md).
- Validate machine-readable task manifests against [`task.schema.json`](./task.schema.json).
- Use `## Batch` for a shared label when several tasks may run in parallel as one upstream batch.
- Use `## Dependency Labels` when a task should wait for every task in one or more upstream batches.
- In JSON manifests, `batch` is optional, `dependency_labels` is an array of batch labels, and `dependencies` is an array of upstream task IDs.

Supervisor status surface:

- Run `scripts/clasp-swarm-status.sh [wave]` for the human-oriented lane and summary view.
- Run `scripts/clasp-swarm-status.sh --json [wave]` for machine-readable lane status plus aggregate run-state counts.
