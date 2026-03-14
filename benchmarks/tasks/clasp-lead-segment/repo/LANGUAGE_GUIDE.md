# Clasp Workspace Guide

This workspace is a small Clasp app with one host adapter.

## Where the real app logic lives

- `Shared/Lead.clasp`
  - shared schema and rendering surface
  - records like `LeadIntake`, `LeadSummary`, and `LeadRecord`
  - page/view helpers like `renderLandingPage`, `renderInboxPage`, and `renderLeadPage`
- `Main.clasp`
  - app flow and typed boundaries
  - `decode` points for host/model JSON
  - route declarations

Start there before touching any JavaScript.

## What the JavaScript files are

- `build/Main.js`
  - generated output
  - never edit this directly
- `runtime/server.mjs`
  - shared runtime adapter
  - treat this as last resort
- `server.mjs`
  - thin host binding layer for seeded data and mock model/storage functions
  - only edit this if the host-side JSON shape or seeded labels must change

For a task like `segment`, the intended first edit is in `Shared/Lead.clasp`, then `Main.clasp`, and only then `server.mjs` if the host bindings must carry the new field.

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
  "cd \"$CLASP_PROJECT_ROOT\" && cabal run claspc -- context \"$workspace_root/Main.clasp\" --compiler=bootstrap"
```

```sh
workspace_root="$(pwd)"
nix develop "$CLASP_PROJECT_ROOT" --command bash -lc \
  "cd \"$CLASP_PROJECT_ROOT\" && cabal run claspc -- air \"$workspace_root/Main.clasp\" --compiler=bootstrap"
```

That writes:

- `Main.context.json`
- `Main.air.json`

Use those to inspect typed routes, boundary declarations, and graph structure before reading generated JS.

## Acceptance loop

- Use `bash scripts/verify.sh` for the final check.
- Let `verify.sh` regenerate `build/Main.js`.
- If acceptance fails, prefer fixing the Clasp schema or route surface before debugging the runtime adapter.
