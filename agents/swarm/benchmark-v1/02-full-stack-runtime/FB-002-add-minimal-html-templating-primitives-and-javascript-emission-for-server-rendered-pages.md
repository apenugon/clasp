# FB-002 Add Compiler-Known View Primitives And Lowering For SSR-First Pages

## Goal

Add compiler-known view primitives and lowering for SSR-first pages.

## Why

The first credible benchmark needs real frontend output in `Clasp`, not only JSON endpoints and host-side rendering glue.
It also cannot paint the language into an `SSR-only` corner. The first rendering layer should stay compiler-owned so later passes can make client/server placement and hydration decisions.

## Scope

- Implement one narrow slice of work: add a small compiler-known view/page surface that `Clasp` code can use to construct pages.
- Represent that surface in the compiler pipeline rather than only through foreign runtime helpers or opaque string builders.
- Keep the first surface intentionally small and benchmark-oriented: escaped text, tags, attributes, child composition, and page-level structure are enough.
- Lower the surface into a dedicated rendering model that the JavaScript emitter owns.
- Emit JavaScript that can SSR render that model into safe HTML while keeping the structure analyzable for future client/server placement.
- Treat the default SSR renderer as an inert safe-by-default surface: event-handler attributes, raw `script` tags, and similar active-content escapes should not be emitted as ordinary view nodes.
- Add one example or regression path that renders an inbox-style page from shared typed data.
- Keep host-JavaScript interop available through typed boundaries; do not assume the page model must own every browser capability itself.
- Leave room for future explicit client modules, client islands, or marked unsafe escape hatches rather than treating arbitrary raw script output as part of the safe default renderer.
- Avoid introducing a full frontend framework, diffing runtime, or full client-side reactivity model in this task.
- Avoid using ad hoc `foreign htmlNode/htmlRender` style helpers as the primary foundation.

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

- `Clasp` can express minimal page/view composition for benchmark pages through compiler-known semantics.
- The syntax/checker/lowering/emitter pipeline owns that rendering surface end to end or through another equally compiler-owned representation.
- The JavaScript output can SSR render that surface into safe inert HTML for server responses.
- The foundation leaves room for later SSR/CSR placement decisions and reactive client behavior without redefining views as opaque strings.
- Tests or regressions cover rendering, escaping, one composed page example, and rejection or neutralization of active-content output in the safe default path.
- `bash scripts/verify-all.sh` passes.

## Verification

```sh
bash scripts/verify-all.sh
```
