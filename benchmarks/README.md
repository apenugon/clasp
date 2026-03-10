# Benchmarks

This directory contains the first benchmark harness scaffold for `Weft`.

The goal is to measure whether AI coding harnesses perform better on realistic software tasks when the target project is written in `Weft` rather than a baseline language.

## Layout

- `run-benchmark.mjs`: task preparation and verification runner
- `result-schema.json`: result record format
- `tasks`: benchmark task manifests, prompts, and baseline repos
- `results`: machine-readable benchmark outputs
- `workspaces`: temporary prepared task copies

## Task Model

Each task includes:

- `task.json`: manifest and verification commands
- `prompt.md`: the task prompt shown to the harness
- `repo`: the starting repository snapshot for that task

The baseline repos are intentionally incomplete. The acceptance tests should fail until the agent finishes the task.

## Commands

List tasks:

```sh
node benchmarks/run-benchmark.mjs list
bun benchmarks/run-benchmark.mjs list
```

Prepare a task workspace:

```sh
node benchmarks/run-benchmark.mjs prepare ts-shared-priority --workspace benchmarks/workspaces/ts-shared-priority
```

Verify a workspace and write a result record:

```sh
node benchmarks/run-benchmark.mjs verify ts-shared-priority \
  --workspace benchmarks/workspaces/ts-shared-priority \
  --harness codex \
  --model gpt-5-codex \
  --interventions 0 \
  --prompt-tokens 0 \
  --completion-tokens 0
```

Run a task plus an external harness command:

```sh
node benchmarks/run-benchmark.mjs run ts-shared-priority \
  --workspace benchmarks/workspaces/ts-shared-priority \
  --harness codex \
  --model gpt-5-codex \
  --agent-command "your-harness-command-here"
```

The runner is harness-agnostic on purpose. It standardizes task prep, verification, and result recording without hard-coding one vendor CLI.

The runner itself is plain ESM and can be executed with either `node` or `bun`. The task manifests currently use `npm` for baseline setup and verification on purpose, because the public benchmark story should avoid changing both the language and the surrounding runtime/tooling at the same time.

## Initial Tasks

- `ts-shared-priority`: shared-type change across frontend and backend
- `ts-agent-escalation`: structured agent-output validation with stricter boundary behavior

These are baseline `TypeScript` tasks meant to establish the first comparison lane for future `Weft` benchmarks.
