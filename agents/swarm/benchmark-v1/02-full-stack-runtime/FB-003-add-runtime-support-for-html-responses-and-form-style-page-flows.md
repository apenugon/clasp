# FB-003 Add Runtime Support For Page Responses, Form Actions, And Future Client/Server Placement

## Goal

Add runtime support for page responses, form actions, and future client/server placement.

## Why

Compiler-known views are not enough by themselves. The benchmark needs runnable pages, GET and POST handlers, and one app flow a human can click through locally.
The runtime contract also needs to preserve a credible path to later client-side reactivity rather than collapsing immediately to raw strings and opaque handlers.

## Scope

- Implement one narrow slice of work: add runtime support for returning page responses from compiled modules built on the compiler-known view/page model.
- Support the minimal routing and request handling needed for page loads, link navigation, and form-style POST flows in the first benchmark app.
- Keep page handlers and action boundaries explicit enough that later tooling can reason about server-only versus browser-facing behavior.
- Add one example or regression path that serves a page, handles a form submission, and returns an updated page.
- Keep the runtime surface small and benchmark-oriented.
- Preserve a clear interop path to richer browser APIs or host-JavaScript helpers through typed boundaries, with future client-side JavaScript flowing through explicit client modules, islands, or equivalent runtime declarations rather than arbitrary inline scripts.
- Avoid introducing a large asset pipeline, SPA router, or hydration framework in this task.

## Likely Files

- `runtime/`
- `src/Clasp/Emit/JavaScript.hs`
- `examples/`
- `test/Main.hs`
- `benchmarks/`

## Dependencies

- `FB-002`

## Acceptance

- Compiled `Clasp` apps can return page responses through the runtime using the compiler-owned view/page model.
- One page flow covering load, submit, and re-render works end to end.
- The runtime contract preserves a credible path to later client-side placement or reactive islands instead of forcing all page logic into opaque server-only strings or unrestricted inline script output.
- Tests or regressions cover the happy path and one invalid input path.
- `bash scripts/verify-all.sh` passes.

## Verification

```sh
bash scripts/verify-all.sh
```
