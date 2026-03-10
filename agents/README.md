# Clasp Agents

This directory holds the repo's agent task backlogs and report schemas.

The canonical backlog now lives under `agents/swarm/`. New work should start from:

- `agents/swarm/task-template.md`
- `agents/swarm/task.schema.json`
- one of the lane directories in `agents/swarm/wave1/` or `agents/swarm/full/`

The swarm path is the default, because it allows:

- one branch per task
- one worktree per active agent
- parallel lanes without shared mutable workspaces
- an accepted-snapshot merge gate that reapplies only verified workspace changes before final verification
- a dedicated integration trunk branch separate from the user's working branch

`agents/tasks/` remains only as the legacy coarse backlog for the older single-supervisor autopilot scripts. It is not the source of truth for new swarm tasks.

The swarm workflow is:

1. `scripts/clasp-swarm-start.sh` launches one supervisor per lane.
2. Each lane reads granular task files from `agents/swarm/<wave>/<lane>/`.
3. The builder subagent implements one task in its dedicated worktree.
4. The verifier reruns the task against a clean baseline worktree.
5. The merge gate advances `agents/swarm-trunk` only after the verification command passes.

The older autopilot workflow is still available for compatibility:

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
```

Swarm task files are ordered lexicographically within each lane and should stay small enough to be completed in a single focused change.
