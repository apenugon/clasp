# Examples

This directory has two kinds of examples:

- small syntax examples for quick smoke checks
- richer multi-file examples that show the current AI-oriented full-stack surface

## Quick Examples

- [hello.clasp](/home/akul/DevProjects/synthspeak/examples/hello.clasp): minimal values and function calls
- [status.clasp](/home/akul/DevProjects/synthspeak/examples/status.clasp): ADTs plus `match`
- [records.clasp](/home/akul/DevProjects/synthspeak/examples/records.clasp): records and field access
- [lists.clasp](/home/akul/DevProjects/synthspeak/examples/lists.clasp): list types, literals, nested list fields, and JSON list boundaries
- [let.clasp](/home/akul/DevProjects/synthspeak/examples/let.clasp): local `let` bindings at the top level and inside `match` branches
- [project/Main.clasp](/home/akul/DevProjects/synthspeak/examples/project/Main.clasp): multi-module imports

## Richer Examples

- [control-plane/Main.clasp](/home/akul/DevProjects/synthspeak/examples/control-plane/Main.clasp): a repo-level control-plane declaration set with guides, policies, hooks, tools, verifiers, and a merge gate for one builder loop
- [control-plane/demo.mjs](/home/akul/DevProjects/synthspeak/examples/control-plane/demo.mjs): runs the compiled control-plane exports through one real agent loop with a simulated repo tool transport
- [interop-ts/Main.clasp](/home/akul/DevProjects/synthspeak/examples/interop-ts/Main.clasp): compiler-managed `npm` and `TypeScript` package imports through foreign declarations with declaration ingestion and generated adapters
- [interop-ts/demo.mjs](/home/akul/DevProjects/synthspeak/examples/interop-ts/demo.mjs): runs the compiled example through the generated package-adapter runtime and prints the resolved results
- [lead-app/Main.clasp](/home/akul/DevProjects/synthspeak/examples/lead-app/Main.clasp): the browser-runnable lead inbox app with typed routes, page rendering, forms, redirects, and one AI-shaped foreign boundary
- [lead-app/mobile-demo.mjs](/home/akul/DevProjects/synthspeak/examples/lead-app/mobile-demo.mjs): a mobile-adjacent projection of the lead inbox that reuses the same compiled Clasp routes and business logic through the React Native bridge
- [support-console/Main.clasp](/home/akul/DevProjects/synthspeak/examples/support-console/Main.clasp): classified customer data, policy-approved projections, typed page flows, auth identity data, and provider/storage boundaries
- [release-gate/Main.clasp](/home/akul/DevProjects/synthspeak/examples/release-gate/Main.clasp): release review pages, typed redirects, audit envelopes with auth and resource identity primitives, and a provider-backed decision boundary

## Useful Commands

Check an example:

```sh
cabal run claspc -- check examples/support-console/Main.clasp
```

Emit AIR:

```sh
cabal run claspc -- air examples/support-console/Main.clasp
```

Verify the `npm`/`TypeScript` interop example:

```sh
bash examples/interop-ts/scripts/verify.sh
```

Emit the context graph:

```sh
cabal run claspc -- context examples/release-gate/Main.clasp
```

Run the control-plane demo after compiling `Main.clasp` into `dist/`:

```sh
mkdir -p dist/control-plane
cabal run claspc -- compile examples/control-plane/Main.clasp -o dist/control-plane/Main.js
node examples/control-plane/demo.mjs dist/control-plane/Main.js
```

Run the browser demo:

```sh
bun examples/lead-app/server.mjs
```

Project the same app into a mobile-friendly model after compiling `Main.clasp` to `Main.js`:

```sh
node examples/lead-app/mobile-demo.mjs examples/lead-app/Main.js
```
