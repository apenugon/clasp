# Benchmarks

This directory contains the first benchmark harness scaffold for `Clasp`.

The goal is to measure whether AI coding harnesses perform better on realistic software tasks when the target project is written in `Clasp` rather than a baseline language.

## Layout

- `run-benchmark.mjs`: task preparation and verification runner
- `run-codex-harness.sh` / `run-claude-harness.sh`: harness wrappers for repeated runs
- `run-codex-series.sh` / `run-claude-series.sh`: repeated-run helpers for mirrored task families
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

For the mirrored `lead-segment` tasks, the prep check also guards the intended mutation surface:

- on the `Clasp` side, swapping in the completed app schema file from `../examples/lead-app/Shared/Lead.clasp` must be enough to reach green without editing the benchmark-only `server.mjs` wrapper or `test/lead-app.test.mjs` scaffold
- on the `TypeScript` side, swapping in the canonical product files from `../examples/lead-app-ts/src/shared/lead.ts` and `../examples/lead-app-ts/src/server/main.ts` must be enough to reach green without editing `test/lead-app.test.mjs`

The repo distinction matters:

- `examples/lead-app` and `examples/lead-app-ts` are canonical runnable baselines for the clickable lead-inbox slice
- `benchmarks/tasks/*/repo` are derived task-starting snapshots that should remain intentionally incomplete for the specific prompt

The canonical lead-inbox slice used to shape new benchmark tasks lives in:

- `examples/lead-app`: `Clasp` baseline
- `examples/lead-app-ts`: `TypeScript` baseline

For agent-boundary and orchestration-heavy work, the benchmark suite also includes:

- `benchmarks/tasks/clasp-control-plane`: `Clasp` control-plane and permission-containment task
- `benchmarks/tasks/ts-control-plane`: mirrored `TypeScript` control-plane baseline
- `benchmarks/tasks/ts-agent-escalation`: typed `TypeScript` agent-boundary task
- `benchmarks/tasks/py-agent-escalation`: mirrored `Python` agent-boundary baseline
- `benchmarks/tasks/clasp-lead-rejection`: `Clasp` trust-boundary rejection task
- `benchmarks/tasks/ts-lead-rejection`: mirrored `TypeScript` trust-boundary rejection task
- `benchmarks/tasks/clasp-external-adaptation`: `Clasp` external-objective adaptation task grounded in the lead outreach reply-rate signal
- `benchmarks/tasks/ts-external-adaptation`: mirrored `TypeScript` external-objective adaptation baseline for the same bounded reply-rate remediation
- `benchmarks/tasks/clasp-npm-interop`: compiler-managed `npm` and TypeScript package interop task
- `benchmarks/tasks/ts-npm-interop`: mirrored handwritten JavaScript package-glue baseline
- `benchmarks/tasks/clasp-python-interop`: compiler-managed Python worker and service interop task
- `benchmarks/tasks/ts-python-interop`: mirrored handwritten JavaScript Python-glue baseline
- `benchmarks/tasks/clasp-rust-interop`: compiler-managed Rust native interop metadata task
- `benchmarks/tasks/ts-rust-interop`: mirrored handwritten JavaScript native-glue baseline
- `benchmarks/tasks/clasp-interop-boundary`: compiler-managed unsafe package refinement and blame-reporting task for unexpected foreign values
- `benchmarks/tasks/ts-interop-boundary`: mirrored handwritten JavaScript refinement baseline for the same unexpected-foreign-value blame surface
- `benchmarks/tasks/clasp-durable-workflow`: durable workflow self-update task covering supervised upgrades, rollback, and version-drain reporting
- `benchmarks/tasks/clasp-compiler-maintenance`: hosted self-hosted compiler maintenance task covering checker, lowering, emitter, and stage-2 bootstrap alignment

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

For the current `Oracle` lead-segment pair, the exact analogous edit surfaces are:

- `benchmarks/tasks/clasp-lead-segment/repo/Shared/Lead.clasp`
- `benchmarks/tasks/ts-lead-segment/repo/src/shared/lead.ts`
- `benchmarks/tasks/ts-lead-segment/repo/src/server/main.ts`

For long-running workflow behavior, the suite also includes `clasp-durable-workflow`, a single-task durable upgrade benchmark that exercises supervised handoff, bounded overlap, health-gated activation, rollback, and version-drain reporting against the worker runtime.

`Raw Repo` is the primary benchmark scorecard. That is the most realistic mode because a real harness has to inspect and understand the environment. `File-Hinted` and `Oracle` are supporting diagnostic modes used to explain *why* one side won, not to replace the main benchmark.

For public scorecards, the main comparison should roll up the mirrored moderate-SaaS app task suite:

- `clasp-lead-priority` vs `ts-lead-priority`
- `clasp-lead-rejection` vs `ts-lead-rejection`
- `clasp-lead-segment` vs `ts-lead-segment`
- `clasp-external-adaptation` vs `ts-external-adaptation`

`node benchmarks/run-benchmark.mjs summarize` now emits this roll-up as `main-public-app-comparison`, with completed-task counts plus suite-level time-to-green, product-feature throughput per hour, and token totals for `Clasp` versus `TypeScript`.

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

When result files include `benchmark-phases.json`, the summary also reports median discovery, first-edit, first-verify, and phase-local time-to-green timings. Summaries and mirrored comparisons stay split by benchmark mode so `Raw Repo`, `File-Hinted`, and `Oracle` remain separate scorecards.

Package a filtered result set into a reproducible benchmark bundle:

```sh
node benchmarks/run-benchmark.mjs package \
  --harness codex \
  --model gpt-5.4 \
  --notes public-app \
  --output dist/benchmarks/public-app.tar.gz
```

The package command writes a stable `tar.gz` archive with the selected result JSON files, the referenced task snapshots, the benchmark runner and harness wrappers, `AGENTS.md`, and a `benchmarks/package-manifest.json` manifest that records the included file digests plus the exact result filters used to build the bundle.

Freeze a publication-grade fairness bundle before running repeated samples:

```sh
node benchmarks/run-benchmark.mjs freeze lead-segment \
  --count 5 \
  --harness codex \
  --model gpt-5.4 \
  --mode raw-repo \
  --notes remediation-1 \
  --output benchmarks/bundles/remediation-1--codex--gpt-5.4--raw-repo.json
```

The freeze manifest records the selected task set, benchmark mode, repeated-sample count, deterministic randomized run order for each sample, and file digests for the frozen task bundle. `run-codex-series.sh` and `run-claude-series.sh` generate this manifest automatically and record its digest in each result record.

When notes end in `-<run-number>`, the summary report treats the shared prefix as a series label. For the mirrored `lead-segment` pair it also prints a comparative section with pass-rate, time-to-green, and token deltas between `Clasp` and `TypeScript`.

Run a repeated Codex sample set with a consistent harness wrapper:

```sh
bash benchmarks/run-codex-series.sh clasp-lead-priority 5 gpt54-series gpt-5.4 raw-repo
```

Run the mirrored repeated control-plane containment pair:

```sh
bash benchmarks/run-codex-series.sh control-plane 5 containment-1 gpt-5.4
node benchmarks/run-benchmark.mjs summarize --harness codex --model gpt-5.4 --notes containment-1
```

Run the same repeated sample set through Claude Code:

```sh
bash benchmarks/run-claude-series.sh clasp-lead-priority 5 sonnet-series sonnet
```

Run the mirrored schema-propagation pair for both languages:

```sh
bash benchmarks/run-codex-series.sh lead-priority 5 remediation-1 gpt-5.4
node benchmarks/run-benchmark.mjs summarize --harness codex --model gpt-5.4 --notes remediation-1
```

Run the mirrored repeated trust-boundary rejection series for both languages:

```sh
bash benchmarks/run-codex-series.sh lead-rejection 5 rejection-1 gpt-5.4
node benchmarks/run-benchmark.mjs summarize --harness codex --model gpt-5.4 --notes rejection-1
```

Run the full mirrored app benchmark that the public scorecard should center on:

```sh
bash benchmarks/run-codex-series.sh app 5 public-app-1 gpt-5.4
node benchmarks/run-benchmark.mjs summarize --harness codex --model gpt-5.4 --notes public-app-1
```

Run the mirrored repeated `lead-segment` series for both languages:

```sh
bash benchmarks/run-codex-series.sh lead-segment 5 remediation-1 gpt-5.4
node benchmarks/run-benchmark.mjs summarize --harness codex --model gpt-5.4 --notes remediation-1
```

Run the mirrored repeated external-objective adaptation series for both languages:

```sh
bash benchmarks/run-codex-series.sh external-adaptation 5 objective-1 gpt-5.4
node benchmarks/run-benchmark.mjs summarize --harness codex --model gpt-5.4 --notes objective-1
```

Run the mirrored repeated foreign-interop series for compiler-managed `npm`, `Python`, and `Rust` versus handwritten host glue:

```sh
bash benchmarks/run-codex-series.sh foreign-interop 5 interop-1 gpt-5.4
node benchmarks/run-benchmark.mjs summarize --harness codex --model gpt-5.4 --notes interop-1
```

Run the mirrored repeated unsafe-refinement and blame-quality pair for unexpected foreign values:

```sh
bash benchmarks/run-codex-series.sh interop-boundary 5 interop-boundary-1 gpt-5.4
node benchmarks/run-benchmark.mjs summarize --harness codex --model gpt-5.4 --notes interop-boundary-1
```

Run the mirrored repeated series for Claude Code:

```sh
bash benchmarks/run-claude-series.sh lead-segment 5 remediation-1 sonnet
node benchmarks/run-benchmark.mjs summarize --harness claude-code --model sonnet --notes remediation-1
```

The runner is harness-agnostic on purpose. It standardizes task prep, verification, and result recording without hard-coding one vendor CLI.

The runner itself is plain ESM and can be executed with either `node` or `bun`. It exports a few environment variables into prepare, verify, and run commands:

- `CLASP_PROJECT_ROOT`
- `CLASP_BENCHMARK_ROOT`
- `CLASP_BENCHMARK_TASK_ID`
- `CLASP_BENCHMARK_WORKSPACE`

That lets Clasp task repos compile against the current compiler without hard-coded local paths. The existing TypeScript task manifests still use `npm` on purpose, because the public benchmark story should avoid changing both the language and the surrounding runtime/tooling at the same time.

When a `codex` run writes `codex-run.jsonl` in the workspace, the runner extracts token usage automatically from the final `turn.completed` event. When a `claude-code` run writes `claude-run.jsonl`, the runner sums the streamed assistant usage records from Claude Code's `stream-json` output. The machine-readable result file records both the benchmark-normalized `tokenUsage` and raw provider counts under `harnessUsage`.

## Initial Tasks

- `ts-shared-priority`: shared-type change across frontend and backend
- `clasp-control-plane`: repo-level control-plane correction with least-privilege permission containment
- `ts-control-plane`: handwritten repo-level control-plane correction with least-privilege permission containment
- `ts-agent-escalation`: structured agent-output validation with stricter boundary behavior
- `py-agent-escalation`: structured agent-output validation with the same escalation contract in a Python baseline
- `clasp-lead-rejection`: typed route plus foreign-boundary rejection with generated Clasp codecs
- `ts-lead-rejection`: mirrored route plus model-boundary rejection in a handwritten TypeScript decoder stack
- `ts-lead-priority`: shared-schema change across a typed route, decoders, and an LLM-shaped model boundary
- `clasp-lead-priority`: shared-schema change across a typed route, generated validation, and an LLM-shaped foreign boundary
- `ts-lead-segment`: clickable lead-inbox change across form input, stored records, HTML rendering, and a validated model echo
- `clasp-lead-segment`: clickable lead-inbox change across form input, shared records, HTML rendering, and a validated foreign-boundary echo
- `clasp-interop-boundary`: compiler-managed unsafe package refinement with blameable unexpected foreign values
- `ts-interop-boundary`: mirrored handwritten refinement and blame-reporting baseline
- `clasp-durable-workflow`: durable workflow hot-swap and self-update scenario with supervised upgrades, rollback, and version-drain reporting
- `clasp-external-adaptation`: reply-rate-driven bounded adaptation over the Clasp lead outreach demo
- `ts-external-adaptation`: mirrored TypeScript reply-rate adaptation benchmark with the same bounded remediation contract
- `clasp-compiler-maintenance`: hosted self-hosted compiler maintenance over the staged compiler bootstrap path
- `clasp-syntax-compact`: compact-source authoring microbenchmark for a single-file Clasp change
- `clasp-syntax-verbose`: the same authoring microbenchmark with an added compiler-generated explain surface

The lead-segment pair should stay isomorphic at the acceptance surface: both tests drive one app-owned server entrypoint, and both variants should keep benchmark-only harness glue out of ordinary product-field propagation work.

The Clasp task is intentionally built around generated validation and route metadata, because that is the first part of the language/runtime stack that should create measurable harness uplift.

For the syntax-form A/B slice, the prepared `clasp-syntax-verbose` workspace includes `benchmark-prep/Main.explain.txt`, which is generated from `claspc explain` and gives a more verbose human-readable rendering of the same compact source.

Run the syntax-form A/B series for Codex:

```sh
bash benchmarks/run-codex-series.sh syntax-form 5 syntax-a gpt-5.4
node benchmarks/run-benchmark.mjs summarize --harness codex --model gpt-5.4 --notes syntax-a
```

Run the same syntax-form A/B series for Claude Code:

```sh
bash benchmarks/run-claude-series.sh syntax-form 5 syntax-a sonnet
node benchmarks/run-benchmark.mjs summarize --harness claude-code --model sonnet --notes syntax-a
```
