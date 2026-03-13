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
- [blocks.clasp](/home/akul/DevProjects/synthspeak/examples/blocks.clasp): multiline block expressions with local declarations, mutable locals, `for` loops, and early `return`
- [compiler-renderers.clasp](/home/akul/DevProjects/synthspeak/examples/compiler-renderers.clasp): self-hosting formatter and diagnostic rendering helpers expressed in Clasp
- [compiler-loader.clasp](/home/akul/DevProjects/synthspeak/examples/compiler-loader.clasp): self-hosting module loading and package search-order helpers expressed in Clasp
- [compiler-parser.clasp](/home/akul/DevProjects/synthspeak/examples/compiler-parser.clasp): self-hosting parser helpers for module headers, imports, signatures, and declaration heads expressed in Clasp
- [project/Main.clasp](/home/akul/DevProjects/synthspeak/examples/project/Main.clasp): multi-module imports

## Richer Examples

- [control-plane/Main.clasp](/home/akul/DevProjects/synthspeak/examples/control-plane/Main.clasp): a repo-level control-plane declaration set with guides, policies, hooks, tools, verifiers, and a merge gate for one builder loop
- [control-plane/demo.mjs](/home/akul/DevProjects/synthspeak/examples/control-plane/demo.mjs): runs the compiled control-plane exports through one real agent loop with a simulated repo tool transport
- [durable-workflow/Main.clasp](/home/akul/DevProjects/synthspeak/examples/durable-workflow/Main.clasp): a minimal durable workflow module used for restart and hot-swap demos
- [durable-workflow/Main.next.clasp](/home/akul/DevProjects/synthspeak/examples/durable-workflow/Main.next.clasp): the supervised replacement module for the durable workflow demo
- [durable-workflow/demo.mjs](/home/akul/DevProjects/synthspeak/examples/durable-workflow/demo.mjs): persists a workflow run to disk, reloads it after a simulated restart, then performs supervised hot-swap activation and retirement
- [interop-ts/Main.clasp](/home/akul/DevProjects/synthspeak/examples/interop-ts/Main.clasp): compiler-managed `npm` and `TypeScript` package imports through foreign declarations with declaration ingestion and generated adapters
- [interop-ts/demo.mjs](/home/akul/DevProjects/synthspeak/examples/interop-ts/demo.mjs): runs the compiled example through the generated package-adapter runtime and prints the resolved results
- [prompt-functions/Main.clasp](/home/akul/DevProjects/synthspeak/examples/prompt-functions/Main.clasp): typed prompt functions built from compiler-known `Prompt` values with explicit system, assistant, and user message composition
- [prompt-functions/demo.mjs](/home/akul/DevProjects/synthspeak/examples/prompt-functions/demo.mjs): compiles a typed prompt function module and prints the resulting prompt payload plus rendered text
- [support-agent/Main.clasp](/home/akul/DevProjects/synthspeak/examples/support-agent/Main.clasp): a renewal-desk agent app that prepares typed tool calls, composes a prompt from tool results, and constrains the final decision to structured reply or escalation schemas
- [support-agent/demo.mjs](/home/akul/DevProjects/synthspeak/examples/support-agent/demo.mjs): runs two typed-tool scenarios through the `createBamlShim` interop surface and validates runtime-selected structured outputs against the compiled schema registry
- [lead-app/Main.clasp](/home/akul/DevProjects/synthspeak/examples/lead-app/Main.clasp): the browser-runnable lead inbox app with typed routes, page rendering, forms, redirects, and one AI-shaped foreign boundary
- [lead-app/ai-demo.mjs](/home/akul/DevProjects/synthspeak/examples/lead-app/ai-demo.mjs): drives an AI-assisted outreach drafting flow, records a business feedback signal, and turns that signal into one bounded prompt-and-test change plan
- [lead-app/client-demo.mjs](/home/akul/DevProjects/synthspeak/examples/lead-app/client-demo.mjs): exercises the lead app's generated JSON route clients against the compiled route surface with no handwritten request codecs
- [lead-app/mobile-demo.mjs](/home/akul/DevProjects/synthspeak/examples/lead-app/mobile-demo.mjs): a mobile-adjacent projection of the lead inbox that reuses the same compiled Clasp routes and business logic through the React Native bridge
- [lead-app/workflow-demo.mjs](/home/akul/DevProjects/synthspeak/examples/lead-app/workflow-demo.mjs): drives a workflow-backed lead follow-up path that starts from the app's typed API routes and continues in the worker runtime
- [support-console/Main.clasp](/home/akul/DevProjects/synthspeak/examples/support-console/Main.clasp): classified customer data, policy-approved projections, typed page flows, auth identity data, and provider/storage structured outputs validated against declared schemas
- [support-console/demo.mjs](/home/akul/DevProjects/synthspeak/examples/support-console/demo.mjs): exercises the dashboard page, projected customer export route, and typed reply-preview form against runtime-installed provider and storage bindings
- [release-gate/Main.clasp](/home/akul/DevProjects/synthspeak/examples/release-gate/Main.clasp): release review pages, typed redirects, audit envelopes with auth and resource identity primitives, and a provider-backed decision boundary
- [release-gate/demo.mjs](/home/akul/DevProjects/synthspeak/examples/release-gate/demo.mjs): runs the release dashboard through review, audit, redirect, and acknowledgement flows with one typed provider binding

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

Verify the typed prompt-function example:

```sh
bash examples/prompt-functions/scripts/verify.sh
```

Verify the support-agent example:

```sh
bash examples/support-agent/scripts/verify.sh
```

Verify the support-console example:

```sh
bash examples/support-console/scripts/verify.sh
```

Verify the release-gate example:

```sh
bash examples/release-gate/scripts/verify.sh
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

Run the durable workflow restart and supervised hot-swap demo after compiling both module versions:

```sh
mkdir -p dist/durable-workflow
cabal run claspc -- compile examples/durable-workflow/Main.clasp -o dist/durable-workflow/Main.js
cabal run claspc -- compile examples/durable-workflow/Main.next.clasp -o dist/durable-workflow/Main.next.js
node examples/durable-workflow/demo.mjs dist/durable-workflow/Main.js dist/durable-workflow/Main.next.js
```

Run the browser demo:

```sh
bun examples/lead-app/server.mjs
```

Project the same app into a mobile-friendly model after compiling `Main.clasp` to `Main.js`:

```sh
node examples/lead-app/mobile-demo.mjs examples/lead-app/Main.js
```

Drive the lead app's workflow-backed follow-up path after compiling `Main.clasp` to `Main.js`:

```sh
node examples/lead-app/workflow-demo.mjs examples/lead-app/Main.js
```

Run the lead app's AI-assisted outreach draft flow after compiling `Main.clasp` to `Main.js`:

```sh
node examples/lead-app/ai-demo.mjs examples/lead-app/Main.js
```
