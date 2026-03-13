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

The baseline repos are intentionally incomplete. The acceptance tests should fail until the agent finishes the task, and `bash benchmarks/test-task-prep.sh` now enforces that the pristine prepared workspaces do not already pass.

For the Clasp `lead-segment` task, the prep check also guards the intended mutation surface: swapping in the completed app schema file from `../examples/lead-app/Shared/Lead.clasp` must be enough to reach green without editing the benchmark-only `server.mjs` wrapper or `test/lead-app.test.mjs` scaffold.

The repo distinction matters:

- `examples/lead-app` and `examples/lead-app-ts` are canonical runnable baselines for the clickable lead-inbox slice
- `benchmarks/tasks/*/repo` are derived task-starting snapshots that should remain intentionally incomplete for the specific prompt

The canonical lead-inbox slice used to shape new benchmark tasks lives in:

- `examples/lead-app`: `Clasp` baseline
- `examples/lead-app-ts`: `TypeScript` baseline

## Benchmark Modes

The lead-inbox benchmark should be reported in three official modes:

- `Raw Repo`: the harness gets the task prompt and ordinary repo docs only. No exact entry-file hints are included. This measures language plus repo-discovery ergonomics.
- `File-Hinted`: the harness gets the same task and acceptance criteria, but the prompt names the analogous starting files in each language variant. This reduces discovery noise and focuses more on edit and verification behavior.
- `Oracle`: the harness gets the same task and acceptance criteria, but the prompt names the exact analogous files expected to change in each language variant. This largely removes discovery variance and isolates propagation, edit, and verification behavior.

Do not collapse these into one number. They answer different questions:

- `Raw Repo` asks whether `Clasp` helps an agent find and bound the change faster.
- `File-Hinted` asks whether `Clasp` helps once the agent is already on the right files.
- `Oracle` asks whether `Clasp` helps once the agent is already on the exact edit surface.

The current mirrored `lead-segment` task pair should remain compatible with all three modes. Prompt variants may differ only in the presence or absence of those file hints; the acceptance surface should stay identical.

`Raw Repo` is the primary benchmark scorecard. That is the most realistic mode because a real harness has to inspect and understand the environment. `File-Hinted` and `Oracle` are supporting diagnostic modes used to explain *why* one side won, not to replace the main benchmark.

## Publication-Grade Fairness

The most defensible benchmark publication mode should freeze a full benchmark bundle:

- task repo snapshots
- prompt files
- `AGENTS.md`
- acceptance tests and commands
- harness wrapper
- run budget and time limit
- benchmark mode (`Raw Repo`, `File-Hinted`, or `Oracle`)

That bundle should then be run:

- with randomized language order
- with repeated samples rather than one-off anecdotes
- with phase-level reporting for discovery, first edit, first verify, and time to green

This is the version of the benchmark that should be treated as the hardest-to-argue-with protocol. It is stricter than the everyday inner-loop benchmark used during language iteration.

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

Run the mirrored schema-propagation pair for both languages:

```sh
bash benchmarks/run-codex-series.sh lead-priority 5 remediation-1 gpt-5.4
node benchmarks/run-benchmark.mjs summarize --harness codex --model gpt-5.4 --notes remediation-1
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
