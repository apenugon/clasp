# Weft

`Weft` is an AI-native universal programming language under active development.

This repository currently contains:

- Design documentation for the language
- A v0 language spec and build roadmap
- A benchmark harness scaffold for measuring agent performance
- A Nix-based Haskell development environment
- The first compiler scaffold, exposed as the `weftc` executable, with parsing, a typed core IR, local type inference, algebraic data types, pattern matching, and JavaScript emission

## Quick Start

```sh
nix develop
cabal build
cabal run weftc -- parse examples/hello.weft
cabal run weftc -- check examples/hello.weft
cabal run weftc -- check examples/hello.weft --json
cabal run weftc -- check examples/status.weft
cabal run weftc -- check examples/inferred.weft
cabal run weftc -- compile examples/hello.weft -o examples/hello.js
cabal test
```

## Repository Layout

- `docs/ai-native-universal-language.md`: long-term design goals
- `docs/weft-benchmark-plan.md`: benchmark strategy and success metrics
- `docs/weft-spec-v0.md`: initial concrete language spec
- `docs/weft-roadmap.md`: phased delivery plan
- `benchmarks`: baseline benchmark repos, manifests, and runner
- `app/Main.hs`: CLI entrypoint
- `src/Weft`: compiler modules
- `examples/hello.weft`: sample source file
- `examples/status.weft`: algebraic-data-type and match example
- `examples/inferred.weft`: unannotated functions inferred from constructors and matches
