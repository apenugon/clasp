# Benchmarks

This directory contains the first benchmark harness scaffold for `Clasp`.

The goal is to measure whether AI coding harnesses perform better on realistic software tasks when the target project is written in `Clasp` rather than a baseline language.

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

The repo distinction matters:

- `examples/lead-app` and `examples/lead-app-ts` are canonical runnable baselines for the clickable lead-inbox slice
- `benchmarks/tasks/*/repo` are derived task-starting snapshots that should remain intentionally incomplete for the specific prompt

The canonical lead-inbox slice used to shape new benchmark tasks lives in:

- `examples/lead-app`: `Clasp` baseline
- `examples/lead-app-ts`: `TypeScript` baseline

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

Summarize recorded runs by task, harness, model, and repeated-run series:

```sh
node benchmarks/run-benchmark.mjs summarize --harness codex --model gpt-5.4
```

When notes end in `-<run-number>`, the summary report treats the shared prefix as a series label. For the mirrored `lead-segment` pair it also prints a comparative section with pass-rate, time-to-green, and token deltas between `Clasp` and `TypeScript`.

Run a repeated Codex sample set with a consistent harness wrapper:

```sh
bash benchmarks/run-codex-series.sh clasp-lead-priority 5 gpt54-series gpt-5.4
```

Run the mirrored repeated `lead-segment` series for both languages:

```sh
bash benchmarks/run-codex-series.sh lead-segment 5 remediation-1 gpt-5.4
node benchmarks/run-benchmark.mjs summarize --harness codex --model gpt-5.4 --notes remediation-1
```

The runner is harness-agnostic on purpose. It standardizes task prep, verification, and result recording without hard-coding one vendor CLI.

The runner itself is plain ESM and can be executed with either `node` or `bun`. It exports a few environment variables into prepare, verify, and run commands:

- `CLASP_PROJECT_ROOT`
- `CLASP_BENCHMARK_ROOT`
- `CLASP_BENCHMARK_TASK_ID`
- `CLASP_BENCHMARK_WORKSPACE`

That lets Clasp task repos compile against the current compiler without hard-coded local paths. The existing TypeScript task manifests still use `npm` on purpose, because the public benchmark story should avoid changing both the language and the surrounding runtime/tooling at the same time.

When a `codex` run writes `codex-run.jsonl` in the workspace, the runner now extracts token usage automatically from the final `turn.completed` event. The machine-readable result file records both the benchmark-normalized `tokenUsage` and raw provider counts under `harnessUsage`.

## Initial Tasks

- `ts-shared-priority`: shared-type change across frontend and backend
- `ts-agent-escalation`: structured agent-output validation with stricter boundary behavior
- `ts-lead-priority`: shared-schema change across a typed route, decoders, and an LLM-shaped model boundary
- `clasp-lead-priority`: shared-schema change across a typed route, generated validation, and an LLM-shaped foreign boundary
- `ts-lead-segment`: clickable lead-inbox change across form input, stored records, HTML rendering, and a validated model echo
- `clasp-lead-segment`: clickable lead-inbox change across form input, shared records, HTML rendering, and a validated foreign-boundary echo

The lead-segment pair should stay isomorphic at the acceptance surface: both tests drive one app-owned server entrypoint, and the Clasp variant should keep benchmark-only harness glue out of ordinary product-field propagation work.

The Clasp task is intentionally built around generated validation and route metadata, because that is the first part of the language/runtime stack that should create measurable harness uplift.
