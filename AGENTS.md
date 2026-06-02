# Clasp Repo Guidance

This repository is building `Clasp`, an AI-oriented programming language with a self-hosted compiler in `src/` and a Rust-native runtime/compiler launcher in `runtime/`.

The Haskell bootstrap compiler is retired. Do not target `cabal`, `app/Main.hs`, `test/Main.hs`, or `deprecated/bootstrap` for active compiler work.

## Working Rules

- Stay inside the current checkout unless a task explicitly requires reading another path.
- Prefer the files named in the task before scanning the wider repo.
- Keep changes small, local, and test-backed.
- Do not rely on Git metadata being available in copied workspaces.
- Run `bash scripts/verify-all.sh` before claiming a task is done. It self-runs under the managed memory guard by default and caps top-level verification fanout; do not bypass that guard except when testing the harness itself.

## Compiler Shape

The main pipeline is:

`source -> parser -> checker -> typed core -> lowered IR -> JavaScript emitter`

The current active implementation is:

- Self-hosted compiler:
  - `src/Main.clasp`
  - `src/Compiler/Ast.clasp`
  - `src/Compiler/Checker.clasp`
  - `src/Compiler/Lower.clasp`
  - `src/Compiler/Emit/JavaScript.clasp`
  - `src/Compiler/Emit/Native.clasp`
  - `src/Compiler/Driver/Frontend.clasp`
  - `src/Compiler/Driver/Native.clasp`
- Promoted native images and caches:
  - `src/embedded.compiler.native.image.json`
  - `src/stage1.compiler.native.image.json`
  - `src/stage1.compiler.module-summary-cache-v2.json`
  - `src/stage1.compiler.source-export-cache-v1.json`
- Native runtime and launcher:
  - `runtime/`
  - `scripts/resolve-claspc.sh`
- Verification:
  - `src/scripts/verify.sh`
  - `scripts/test-native-claspc.sh`
  - `scripts/test-swarm-ready-gate.sh`
  - focused `scripts/test-*.sh` harnesses

## Task Discipline

- Treat each task as one focused feature slice.
- Add or update tests with each behavior change.
- When a task changes runtime behavior, trust boundaries, workflows, interop, page/app flows, or other user-visible execution surfaces, add or update at least one scenario-level or end-to-end verification path, not just a local regression.
- Only update docs when visible language or runtime behavior changes.
- If a task fails verification twice, prefer a narrower workaround over a broad redesign.
