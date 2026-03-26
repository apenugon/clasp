# Task: Maintain the Hosted Self-Hosted Compiler Path

This repository models one narrow compiler-maintenance benchmark on the hosted self-hosted compiler path.

The current self-hosted slice keeps a tiny checker, lowering pass, and JavaScript emitter aligned for string and function declarations. Extend that path so a boolean preview flag is maintained end to end through the same hosted bootstrap flow.

## Working Guidance

- This task is intentionally local to the workspace.
- Start with `test/compiler-maintenance.test.mjs`, then inspect `Main.clasp` and the files under `Compiler/`.
- Do not inspect the parent repo unless `bash scripts/verify.sh` exposes a benchmark harness or compiler/runtime bug rather than a task-repo bug.
- Keep the fix in the copied self-hosted compiler slice. Do not patch the test to relax the scenario.

## Requirements

- Add a boolean preview flag declaration to the hosted self-hosted sample pipeline.
- Keep checker inference aligned so the preview flag is inferred as `Bool`.
- Keep lowering aligned so the preview flag renders as a boolean literal in the lowered summary.
- Keep JavaScript emission aligned so the emitted module exports `previewEnabled = true`.
- Preserve the existing string constant and render function behavior.
- Preserve the hosted bootstrap flow where stage 1 emits a stage 2 compiler module and stage 2 reproduces the same emitted sample module.

## Constraints

- Keep the codebase small and readable.
- Preserve the existing hosted bootstrap shape in `Main.clasp` and `demo.mjs`.
- Do not bypass the self-hosted path by hard-coding the expected JSON in JavaScript.

## Acceptance

The task is complete when `bash scripts/verify.sh` passes.
