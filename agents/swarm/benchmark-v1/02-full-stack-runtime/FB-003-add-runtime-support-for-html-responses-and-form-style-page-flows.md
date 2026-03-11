# FB-003 Add Runtime Support For HTML Responses And Form-Style Page Flows

## Goal

Add runtime support for HTML responses and form-style page flows.

## Why

Minimal templates are not enough by themselves. The benchmark needs runnable pages, GET and POST handlers, and one app flow a human can click through locally.

## Scope

- Implement one narrow slice of work: add runtime support for returning HTML responses from compiled modules.
- Support the minimal routing and request handling needed for page loads, link navigation, and form-style POST flows in the first benchmark app.
- Add one example or regression path that serves a page, handles a form submission, and returns an updated page.
- Keep the runtime surface small and benchmark-oriented.
- Avoid introducing a large asset pipeline, SPA router, or hydration framework.

## Likely Files

- `runtime/`
- `src/Clasp/Emit/JavaScript.hs`
- `examples/`
- `test/Main.hs`
- `benchmarks/`

## Dependencies

- `FB-002`

## Acceptance

- Compiled `Clasp` apps can return HTML pages through the runtime.
- One page flow covering load, submit, and re-render works end to end.
- Tests or regressions cover the happy path and one invalid input path.
- `bash scripts/verify-all.sh` passes.

## Verification

```sh
bash scripts/verify-all.sh
```
