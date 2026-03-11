# FB-002 Add Minimal HTML Templating Primitives And JavaScript Emission For Server-Rendered Pages

## Goal

Add minimal HTML templating primitives and JavaScript emission for server-rendered pages.

## Why

The first credible benchmark needs real frontend output in `Clasp`, not only JSON endpoints and host-side rendering glue.

## Scope

- Implement one narrow slice of work: add a small HTML/view surface that `Clasp` code can use to construct server-rendered pages.
- Keep the surface intentionally small and benchmark-oriented: escaped text, tags, attributes, and child composition are enough.
- Emit JavaScript that can render the HTML surface into a response-safe string or equivalent page representation.
- Add one example or regression path that renders an inbox-style page from shared typed data.
- Avoid introducing a full frontend framework, diffing runtime, or client-side reactivity model.

## Likely Files

- `src/Clasp/Syntax.hs`
- `src/Clasp/Parser.hs`
- `src/Clasp/Checker.hs`
- `src/Clasp/Lower.hs`
- `src/Clasp/Emit/JavaScript.hs`
- `runtime/`
- `examples/`
- `test/Main.hs`
- `docs/clasp-spec-v0.md`

## Dependencies

- `FB-001`

## Acceptance

- `Clasp` can express minimal HTML templates or view composition for benchmark pages.
- The JavaScript output can render that surface into safe HTML for server responses.
- Tests or regressions cover rendering, escaping, and one composed page example.
- `bash scripts/verify-all.sh` passes.

## Verification

```sh
bash scripts/verify-all.sh
```
