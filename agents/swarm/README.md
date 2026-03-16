# Clasp Swarm

This directory contains the worktree-based swarm backlogs.

Canonical task-manifest assets live here too:

- `agents/swarm/task-template.md`: markdown template for new swarm tasks
- `agents/swarm/task.schema.json`: schema for the parsed machine-readable manifest projected from each task file

The runtime validates every task file against that schema before a lane lists or selects tasks. The canonical identity model is:

- `taskId`: the markdown basename without `.md`
- `taskKey`: the leading `SW-001` style key derived from the basename and `#` heading
- `title`: the remainder of the `#` heading after the task key

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
5. Final verification runs again against an accepted-snapshot worktree
6. Only the verified workspace delta is copied into the accepted snapshot before `main` and `agents/swarm-trunk` advance

Supervisor status is available in both human and machine-readable forms:

- `bash scripts/clasp-swarm-status.sh`: lane-by-lane text summary with current run state plus an aggregated `run-states:` line for the latest lane outcomes
- `bash scripts/clasp-swarm-status.sh --json`: structured lane status for tooling and dashboards, including `summary.runStateCounts`

Wave directories:

- `full/`: full materialized project backlog and the default swarm target
- `wave1/`: initial swarm-infrastructure and core-language slices
- `benchmark-v0/`: focused critical path to the first credible lead-inbox benchmark
- `benchmark-v1/`: clickable vertical-slice benchmark with HTML templating and browser-runnable flows in both repos
- `benchmark-win-v0/`: focused remediation wave to beat the mirrored TypeScript baseline on the clickable lead-segment benchmark
- `auth-air-v0/`: focused first pass on AIR, authorization primitives, proof-carrying access, and field-level data classification
