# Clasp Repo Guidance

This repository is building `Clasp`, an AI-oriented programming language compiler in Haskell.

## Working Rules

- Stay inside the current checkout unless a task explicitly requires reading another path.
- Prefer the files named in the task before scanning the wider repo.
- Keep changes small, local, and test-backed.
- Do not rely on Git metadata being available in copied workspaces.
- Run `bash scripts/verify-all.sh` before claiming a task is done.

## Compiler Shape

The main pipeline is:

`source -> parser -> checker -> typed core -> lowered IR -> JavaScript emitter`

The main implementation files are:

- `src/Clasp/Syntax.hs`
- `src/Clasp/Parser.hs`
- `src/Clasp/Checker.hs`
- `src/Clasp/Core.hs`
- `src/Clasp/Lower.hs`
- `src/Clasp/Emit/JavaScript.hs`
- `src/Clasp/Compiler.hs`
- `test/Main.hs`

## Task Discipline

- Treat each task as one focused feature slice.
- Add or update tests with each behavior change.
- When a task changes runtime behavior, trust boundaries, workflows, interop, page/app flows, or other user-visible execution surfaces, add or update at least one scenario-level or end-to-end verification path, not just a local regression.
- Only update docs when visible language or runtime behavior changes.
- If a task fails verification twice, prefer a narrower workaround over a broad redesign.
