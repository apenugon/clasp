# Weft

`Weft` is an AI-native universal programming language under active development.

This repository currently contains:

- Design documentation for the language
- A v0 language spec and build roadmap
- A benchmark harness scaffold for measuring agent performance
- A Nix-based Haskell development environment
- The first compiler scaffold, exposed as the `weftc` executable, with parsing, a typed core IR, a lowered backend IR, local type inference, algebraic data types, schema-bearing records, multi-file imports, foreign runtime bindings, typed HTTP routes, JSON boundary operators, and JavaScript emission

## Quick Start

```sh
nix develop
cabal build
cabal run weftc -- parse examples/hello.weft
cabal run weftc -- check examples/hello.weft
cabal run weftc -- check examples/hello.weft --json
cabal run weftc -- check examples/status.weft
cabal run weftc -- check examples/inferred.weft
cabal run weftc -- check examples/records.weft
cabal run weftc -- check examples/project/Main.weft
cabal run weftc -- check examples/lead-app/Main.weft
cabal run weftc -- compile examples/hello.weft -o examples/hello.js
cabal run weftc -- compile examples/project/Main.weft -o examples/project/Main.js
cabal run weftc -- compile examples/lead-app/Main.weft -o examples/lead-app/Main.js
bun examples/lead-app/server.mjs
cabal test
```

## Repository Layout

- `docs/ai-native-universal-language.md`: long-term design goals
- `docs/weft-benchmark-plan.md`: benchmark strategy and success metrics
- `docs/weft-spec-v0.md`: initial concrete language spec
- `docs/weft-roadmap.md`: phased delivery plan
- `benchmarks`: baseline benchmark repos, manifests, and runner
- `app/Main.hs`: CLI entrypoint
- `runtime/bun`: Bun runtime helpers for typed route serving
- `src/Weft`: compiler modules
- `examples/hello.weft`: sample source file
- `examples/status.weft`: algebraic-data-type and match example
- `examples/inferred.weft`: unannotated functions inferred from constructors and matches
- `examples/records.weft`: record literals and field access
- `examples/project`: multi-file import example
- `examples/lead-app`: typed route and foreign-boundary demo app
