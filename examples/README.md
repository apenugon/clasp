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

- [lead-app/Main.clasp](/home/akul/DevProjects/synthspeak/examples/lead-app/Main.clasp): the browser-runnable lead inbox app with typed routes, page rendering, forms, redirects, and one AI-shaped foreign boundary
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

Emit the context graph:

```sh
cabal run claspc -- context examples/release-gate/Main.clasp
```

Run the browser demo:

```sh
bun examples/lead-app/server.mjs
```
