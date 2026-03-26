# Task: Add Lead Segment Across the Clickable Inbox App

The repository models a browser-runnable lead inbox with:

- a server-rendered HTML intake form
- a clickable inbox page and lead detail pages
- a shared lead contract used by request decoding, storage, and rendering
- a mock model boundary that still returns raw JSON

Implement lead segments end to end.

## Working Guidance

- This task is intentionally local to the workspace.
- Start with `test/lead-app.test.mjs` and the shared lead contract or rendering file in this workspace.
- Do not inspect the parent repo unless `bash scripts/verify.sh` exposes a benchmark harness or language-runtime bug rather than an app bug.
- The intended app-level fix is to express the constraint in the shared schema and thread it through the existing server-rendered flow.

## Requirements

- Extend lead intake so the form accepts a `segment`.
- Restrict `segment` to `startup`, `growth`, and `enterprise`.
- Persist the segment in stored lead records.
- Show the segment on the rendered lead page.
- Update the inbox labels so a human can see the lead segment before clicking through.
- Ensure the created lead page and the inbox page both reflect the submitted segment after a new lead is added.
- Pass the intake segment through the mock model boundary and require the final stored lead to use the validated segment returned by that boundary.
- Missing or invalid `segment` values should be rejected at the form/request boundary.
- Invalid `segment` values coming back from the mock model boundary should be rejected before HTML is rendered.
- Preserve the existing priority and review flows.

## Constraints

- Keep the codebase small and readable.
- Preserve the existing route structure and server-rendered page flow.
- Do not bypass validation with unchecked shortcuts or generated-output edits.

## Acceptance

The task is complete when `bash scripts/verify.sh` passes.
