# Clasp Autopilot

This directory defines the task queue and schemas for the long-running builder/verifier subagent pair.

The intended workflow is:

1. `scripts/clasp-autopilot-start.sh` launches a background supervisor.
2. The supervisor creates or resumes the rolling branch `agents/autopilot`.
3. For each task in `agents/tasks/`:
   - a builder subagent implements the task in the builder worktree
   - a verifier subagent runs in a disposable verification worktree
   - full repo verification runs through `scripts/verify-all.sh`
4. If verification passes, the supervisor commits the task on `agents/autopilot` and moves to the next task.
5. If verification fails repeatedly, the supervisor stops and leaves logs and reports in `.clasp-agents/`.

Useful commands:

```sh
bash scripts/clasp-autopilot-start.sh
bash scripts/clasp-autopilot-status.sh
bash scripts/clasp-autopilot-stop.sh
```

Task files are ordered lexicographically and should stay small enough to be completed in a single focused change.
