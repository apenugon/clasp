# Iteration Speed Loop Evidence

## Scope

This slice narrows the default self-hosted verify loop instead of trying to solve the full cold self-hosted rebuild in one pass.

The hot paths still under active pressure are:

- `runtime/target/debug/claspc --json check src/CompilerMain.clasp`
- `runtime/target/debug/claspc exec-image src/embedded.compiler.native.image.json checkProjectText --project-entry=src/CompilerMain.clasp ...`
- `runtime/target/debug/claspc exec-image src/embedded.compiler.native.image.json nativeImageProjectText --project-entry=src/Main.clasp ...`
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

## Structural Win

The old default loop rebuilt a fresh hosted native image even in `fast` mode before it did any lighter checks.

The new split removes that rebuild from the default path:

- `fast` is now a check-oriented loop
- `full` remains the rebuild-and-compare loop

That is a real workflow win for repeated compiler edits because the default path no longer pays the full hosted image rebuild up front.

## Limits

- The timing numbers above are lower bounds because both exact hot-path commands were still running when I stopped the capture on this host.
- The direct self-hosted `src/CompilerMain.clasp` check is still a dominant cost center on this host, and the full verify loop still pays for `nativeImageProjectText` on `src/Main.clasp`.
- The remaining bottleneck is still the native self-hosted compiler work itself, especially the cold `src/CompilerMain.clasp` check and the cold `nativeImageProjectText` rebuild for the broader `src/Main.clasp` surface.
- If the next slice wants a stronger acceptance story, it should attack invalidation boundaries or persisted semantic caches now that the smaller dedicated compiler entrypoint is in place.
