# Contract Upgrade Suite

This suite extends the single `lead-digest-upgrade` eval into a small family of comparable Clasp contract-upgrade tasks.

Each task uses the same shared `start/` state:

- `common/start/Main.clasp`
- `common/start/Shared/Lead.clasp`

Each task then defines a different target contract and known-good solution under `tasks/<task-id>/solution/`.

## Task Family

The suite currently includes:

- `lead-digest-upgrade`
- `lead-profile-upgrade`
- `lead-follow-up-window-upgrade`
- `lead-channel-digest-upgrade`

All four tasks stay in the same narrow slice:

- two Clasp source files
- one route contract
- one tool request contract
- one workflow state contract
- one `main` value used as a simple runtime check

## Benchmark Modes

The live runner supports the three benchmark modes described in the repo docs:

- `raw-repo`
- `file-hinted`
- `oracle`

It also compares two assistance variants for the same task and mode:

- `raw-text`
- `compiler-owned-air`

## Verification

To verify all task solutions locally:

```bash
bash src/evals/contract-upgrade-suite/test.sh
```

## Live Codex Runs

To run the full suite with default settings:

```bash
bash src/evals/contract-upgrade-suite/run-live-codex-suite.sh
```

Useful environment variables:

- `CLASP_SUITE_TASKS=lead-digest-upgrade,lead-profile-upgrade`
- `CLASP_SUITE_MODES=raw-repo,file-hinted,oracle`
- `CLASP_SUITE_ASSISTANCES=raw-text,compiler-owned-air`
- `CLASP_SUITE_SAMPLES=1`
- `CLASP_LIVE_MODEL=gpt-5.4`
- `CLASP_LIVE_REASONING_EFFORT=high`
- `CLASP_KEEP_WORKSPACES=true`

Results are written under `results/`.

## Metrics

Each live run records:

- pass/fail
- duration
- total tokens
- uncached tokens
- verify attempts
- repair loops
- time-to-green
- changed-file count

The suite summary also records pairwise deltas between `raw-text` and `compiler-owned-air` for the same task, mode, and sample.
