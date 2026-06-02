# Clasp Autopilot

This directory defines the task queue and schemas for the long-running builder/verifier subagent pair.

There are currently two agent paths in the repo:

1. `agents/tasks/` for the older single-supervisor autopilot path
2. `agents/swarm/` for the newer worktree-and-branch-based swarm path

The long-term direction is the swarm path, because it allows:

- one branch per task
- one worktree per active agent
- parallel lanes without shared mutable workspaces
- a rebase and final verification gate before integration
- a dedicated integration trunk branch separate from the user's working branch

The intended workflow is:

1. `scripts/clasp-autopilot-start.sh` launches a background supervisor.
2. The supervisor creates or resumes the rolling branch `agents/autopilot`.
3. For each task in `agents/tasks/`:
   - a builder subagent implements the task in the builder worktree
   - a verifier subagent runs in a disposable verification worktree
   - full repo verification runs through `scripts/verify-all.sh`
4. If verification passes, the supervisor rolls the verified snapshot forward and moves to the next task.
5. If verification fails repeatedly on a base task, the supervisor generates one narrower workaround task and keeps going.
6. If a workaround task still fails repeatedly, the supervisor leaves it blocked and continues to later tasks.

The runtime logs and state live in `.clasp-agents/` inside the repo. The linked Git worktrees for the builder and verifier live outside the repo so Git does not confuse them with tracked content.

Useful commands:

```sh
bash scripts/clasp-autopilot-start.sh
bash scripts/clasp-autopilot-status.sh
bash scripts/clasp-autopilot-stop.sh

bash scripts/clasp-swarm-start.sh wave1
bash scripts/clasp-swarm-status.sh wave1
bash scripts/clasp-swarm-stop.sh wave1

bash scripts/clasp-swarm-start.sh --profile bounded-low-memory --preflight-json wave1
bash scripts/clasp-swarm-start.sh --profile bounded-low-memory wave1
```

By default, `clasp-swarm-start.sh` starts at most one running lane and launches
each lane through the managed job memory guard. The guard enforces both a
per-process virtual-memory limit and a session-level aggregate RSS watcher. When
the user systemd manager is available it also runs the workload in a
`MemoryMax` scope, leaving the detached metadata runner outside the scope so it
can still record an exit status after a kernel-enforced memory stop. A lane that
fans out into multiple large children is stopped before it can exhaust the VM. Use
`CLASP_SWARM_MAX_RUNNING_LANES`, `CLASP_SWARM_LANE_MEMORY_MB`, and
`CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB` to tune larger machines deliberately. Use
`--profile bounded-low-memory` to preflight or start one managed lane with a
4 GiB lane memory cap and 32 GiB host-memory reserve on a constrained machine.
The `clasp-swarm-start.sh --preflight` and `--preflight-json` paths also check
the launch repository gate, so a dirty worktree or non-main branch is reported
as a blocked start before any lane is launched. Direct
`clasp-swarm-preflight.sh` remains available for resource-only checks unless
`--include-repository-gate` is passed.
The standalone codex-loop and autopilot launchers use the same managed-job
memory guard by default.
Raw agent entrypoints such as `clasp-codex-loop.sh`, `clasp-autopilot.sh`,
`clasp-builder.sh`, and `clasp-verifier.sh` refuse unmanaged real agent work;
use the `*-start.sh` launchers, wrap with `scripts/run-managed-job.sh`, or set
`CLASP_ALLOW_UNMANAGED_AGENT_RUNTIME=1` only for lightweight tests and fixtures.

Task files are ordered lexicographically and should stay small enough to be completed in a single focused change.
