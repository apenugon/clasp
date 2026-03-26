# Autonomous Swarm Near-Term Roadmap

This is the near-term roadmap for getting Clasp to the point where an autonomous swarm of Clasp-capable agents can make sustained progress on the compiler and runtime without falling back to deprecated bootstrap paths.

## Immediate Priorities

1. Make `claspc` truly image-driven.
   - keep `claspc` as a thin native launcher over the promoted compiler image
   - move more CLI ownership into Clasp itself: args, file output, export dispatch, whole-project planning
   - keep Rust limited to runtime/kernel concerns and image loading

2. Improve compiler-authoring ergonomics in the self-hosted language.
   - collection helpers: `map`, `fold`, `filter`, `find`, `any`, `all`, `concat`
   - a basic dictionary/map type for compiler metadata, manifests, and lookup-heavy passes
   - better structured literals, destructuring, and record update ergonomics

3. Finish native backend surface parity.
   - routes and server responses: richer `Page` / `View` / `Redirect` support
   - workflows, hooks, tools, agents, policies, verifier/mergegate, and control-plane surfaces
   - remove deprecated backend JS shims after each surface is truly native-backed

4. Make unsupported surfaces fail early and clearly.
   - detect unsupported self-hosted/native features before broken output is emitted
   - prefer direct diagnostics over fallback behavior or partial generation

## Near-Term Slices

- runtime-backed `argv`, file output, and stdout/stderr so compiler behavior can keep moving out of Rust
- simple native server primitives first, then richer page/view builders
- focused self-hosted verification that stays off `verify-all` during iteration
- native-only backend packaging by copying runtime bytes plus embedded Clasp image

## Definition Of Progress

- ordinary compiler iteration uses `claspc`, not deprecated bootstrap commands
- backend examples compile into native executables with embedded Clasp images
- self-hosted compiler changes can be verified with focused native smoke tests
- multiple agents can work in parallel because the language/runtime is ergonomic enough for nontrivial compiler changes
