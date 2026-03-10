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
