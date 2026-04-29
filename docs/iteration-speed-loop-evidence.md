# Iteration Speed Loop Evidence

## Scope

This slice narrows the default self-hosted verify loop and adds promoted module-summary seeding for unchanged promoted compiler sources.

The hot paths still under active pressure are:

- `runtime/target/debug/claspc --json check src/CompilerMain.clasp`
- `runtime/target/debug/claspc exec-image src/embedded.compiler.native.image.json checkProjectText --project-entry=src/CompilerMain.clasp ...`
- `runtime/target/debug/claspc exec-image src/embedded.compiler.native.image.json nativeImageProjectText --project-entry=src/Main.clasp ...`
- `runtime/target/debug/claspc --json check src/Main.clasp`
- `env CLASP_NATIVE_VERIFY_MODE=fast bash src/scripts/verify.sh`
- `env CLASP_NATIVE_VERIFY_MODE=full bash src/scripts/verify.sh`

## What Changed

- `src/scripts/verify.sh` now treats `fast` as a lighter developer loop.
- The self-hosted rebuild path continues to use the narrower compiler image rooted at `src/CompilerMain.clasp` for `src/embedded.compiler.native.image.json`, so rebuild-heavy verification avoids dragging unrelated `Main` exports into that image.
- `fast` now stays entirely on the compiler-only path: it runs `checkProjectText` through the promoted compiler image for `src/CompilerMain.clasp`, then runs the native CLI check path directly on that same entrypoint:

```bash
runtime/target/debug/claspc exec-image src/embedded.compiler.native.image.json checkProjectText --project-entry=src/CompilerMain.clasp /tmp/clasp-compiler.check.txt
runtime/target/debug/claspc --json check src/CompilerMain.clasp
```

- `full` keeps the promotion-equivalence loop, including the self-hosted native-image rebuild and promoted-vs-rebuilt comparisons.
- The scenario check in `scripts/test-selfhost-verify-mode-split.sh` proves that `fast` avoids `nativeImageProjectText`, while `full` still exercises it.
- The native CLI now embeds `src/stage1.compiler.module-summary-cache-v2.json`, a promoted module-summary seed for the `src/Main.clasp` self-host import closure.
- `scripts/generate-promoted-module-summary-cache.mjs --check` verifies that the promoted seed is reproducible from the current promoted compiler image and source closure.
- `scripts/test-selfhost.sh` now checks a fresh-cache `src/Main.clasp` check and requires promoted module-summary hits for `Compiler.Ast`, `Compiler.Emit.JavaScript`, and `Main`.

## Measured Timings

Timing capture date: `2026-03-26` (UTC).

These numbers come from the real self-hosted commands in this checkout. The `verify.sh` comparison is the before/after story for the workflow change because the old default loop was equivalent to today's `full` mode, while the new default loop is `fast`.

- Before default loop:
  `env CLASP_NATIVE_VERIFY_MODE=full bash src/scripts/verify.sh`
- After default loop:
  `env CLASP_NATIVE_VERIFY_MODE=fast bash src/scripts/verify.sh`
- Targeted underlying hot paths:
  `runtime/target/debug/claspc --json check src/CompilerMain.clasp`
  `runtime/target/debug/claspc exec-image src/embedded.compiler.native.image.json checkProjectText --project-entry=src/CompilerMain.clasp /tmp/clasp-compiler.check.txt`
  `runtime/target/debug/claspc exec-image src/embedded.compiler.native.image.json nativeImageProjectText --project-entry=src/Main.clasp /tmp/clasp-native-image.json`
- Host observations captured on `2026-03-26`:
  `runtime/target/debug/claspc --json check src/CompilerMain.clasp` was still running at `622s` when I stopped the timing capture.
  `runtime/target/debug/claspc exec-image src/embedded.compiler.native.image.json checkProjectText --project-entry=src/CompilerMain.clasp /tmp/clasp-compiler.check.txt` was still running at `167s` when I stopped the timing capture.
  `runtime/target/debug/claspc exec-image src/embedded.compiler.native.image.json nativeImageProjectText --project-entry=src/Main.clasp /tmp/clasp-native-image.json` was still running at `167s` when I stopped the timing capture.
- Concrete workflow delta:
  the new default `fast` loop removes the `nativeImageProjectText` step from the default path and narrows the direct CLI check to `src/CompilerMain.clasp`, so it avoids at least `167s` of extra self-hosted wall-clock on this host before counting the rest of `full` mode's promoted-vs-rebuilt comparison work.

Latest promoted-cache capture date: `2026-04-29` (UTC).

These numbers come from the iteration-speed builder/verifier loop rooted at `.clasp-loops/iteration-speed-gpt55-xhigh-hostpass`.

- Before promoted module-summary seeding:
  `timeout 120s claspc --json check src/Main.clasp` exited with status `124`.
- After promoted module-summary seeding:
  `timeout 120s env XDG_CACHE_HOME=<fresh> CLASP_NATIVE_TRACE_CACHE=1 ./runtime/target/debug/claspc --json check src/Main.clasp` completed in about `0.31s`.
- The verifier observed `18` promoted module-summary hits, including `Compiler.Ast`, `Compiler.Emit.JavaScript`, and `Main`.
- The same verifier pass ran `bash scripts/verify-all.sh` successfully.
- The incremental native probe still reports roughly `10.9s` cold check/native-image paths for the small measured project, with body-change paths around `0.26s` to `0.30s`.

## Structural Win

The old default loop rebuilt a fresh hosted native image even in `fast` mode before it did any lighter checks.

The new split removes that rebuild from the default path:

- `fast` is now a check-oriented loop
- `full` remains the rebuild-and-compare loop

That is a real workflow win for repeated compiler edits because the default path no longer pays the full hosted image rebuild up front.

The promoted module-summary seed is a second structural win: a fresh checkout or fresh cache can hydrate normal module-summary cache entries for unchanged promoted self-host modules without re-running the slow semantic checker for those modules. This specifically addresses the verifier-blocking `src/Main.clasp` check path.

The gate for this behavior is permanent in the normal verification path:

- `scripts/verify-all.sh` runs `bash scripts/test-selfhost.sh`
- `scripts/test-selfhost.sh` runs `node scripts/generate-promoted-module-summary-cache.mjs --check`
- `scripts/test-selfhost.sh` checks fresh-cache `src/Main.clasp`
- `scripts/test-selfhost.sh` requires promoted hits for `Compiler.Ast`, `Compiler.Emit.JavaScript`, and `Main`

## Limits

- The March timing numbers are lower bounds because both exact hot-path commands were still running when I stopped the capture on this host.
- The promoted seed is a strong win for unchanged promoted self-host modules. It is not a full solution for arbitrary edits to large compiler modules.
- If a large seeded module changes, its source fingerprint changes and the current checker can still fall back to expensive semantic work for that module.
- The next speed slice should attack true cold semantic checking for edited large modules, especially `Compiler.Ast`, `Compiler.Checker`, `Compiler.Emit.JavaScript`, `Compiler.Project`, and `Compiler.SemanticArtifacts`.
