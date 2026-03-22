# Clasp Workspace Guide

This workspace is a small Clasp app verified through a native runtime harness.

## Where the real app logic lives

- `Shared/Lead.clasp`
  - shared schema and rendering surface
  - records like `LeadIntake`, `LeadSummary`, and `LeadRecord`
  - page/view helpers like `renderLandingPage`, `renderInboxPage`, and `renderLeadPage`
- `Main.clasp`
  - app flow and typed boundaries
  - `decode` points for host/model JSON
  - route declarations

Start there before touching the verification harness.

## What the verification files are

- `test/lead-app.test.mjs`
  - packaged-native acceptance scaffolding
  - validates HTTP behavior against the generated binary
- `scripts/verify.sh`
  - compiles the workspace to a native binary
  - runs the acceptance test with `CLASP_BENCH_BINARY`

For a task like `segment`, the intended first edit is in `Shared/Lead.clasp`, then `Main.clasp`. The test harness should stay unchanged unless there is a real native-runtime bug.

## Useful Clasp patterns in this workspace

- `record ... = { ... }`
  - schema shared across forms, storage, rendering, and decode boundaries
- `type ... = ... | ...`
  - tagged union / enum-style types
- `decode SomeRecord (foreignCall value)`
  - runtime boundary validation from host JSON into a typed Clasp value
- `route name = METHOD "/path" RequestType -> ResponseType handler`
  - typed route declaration
- `page`, `element`, `text`, `append`, `form`, `input`, `submit`, `link`
  - compiler-known page/view primitives

## Fast semantic inspection

From the workspace root, these commands emit compiler-owned artifacts for this app:

```sh
workspace_root="$(pwd)"
nix develop "$CLASP_PROJECT_ROOT" --command bash -lc \
  "cd \"$CLASP_PROJECT_ROOT\" && claspc context \"$workspace_root/Main.clasp\""
```

```sh
workspace_root="$(pwd)"
nix develop "$CLASP_PROJECT_ROOT" --command bash -lc \
  "cd \"$CLASP_PROJECT_ROOT\" && claspc air \"$workspace_root/Main.clasp\""
```

That writes:

- `Main.context.json`
- `Main.air.json`

Use those to inspect typed routes, boundary declarations, and graph structure before debugging native route behavior.

## Acceptance loop

- Use `bash scripts/verify.sh` for the final check.
- Let `verify.sh` regenerate the packaged native binary.
- If acceptance fails, prefer fixing the Clasp schema or route surface before debugging the native runtime.
