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
- `scripts/verify-affected.mjs` now keeps the expensive `swarm-feedback-loop` runtime slice on FeedbackLoop-specific files instead of every generic `examples/swarm-native/*` change; shared swarm-native library edits still run native claspc, readiness, memory, context-pack, monitored-loop, and managed-loop coverage.

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

Latest cache-key byte memoization capture date: `2026-05-31` (UTC).

These numbers come from the guarded measurement job `focused-native-incremental-file-cache-safe-1`:

```bash
bash scripts/measure-native-incremental.sh --scenario native-cli-body-change --assert --report .clasp-verify/reports/native-incremental-file-cache-safe-1.json
```

- The assertion passed with no cache-behavior mismatches.
- `nativeImageCold` completed in `22.93s`.
- `nativeImageBodyChange` completed in `21.11s`.
- `checkCold` completed in `21.09s`.
- `checkBodyChange` completed in `0.54s`.
- The measured body edit kept the expected module-summary behavior: `Shared.User` was a `validated-hit`, while `Shared.Render` and `Main` were normal `hit`s.

Latest in-process changed-decl export capture date: `2026-05-31` (UTC).

The guarded timing probe `native-incremental-cache-timing-safe-1` showed the remaining native-image body-change cost was not build-plan or assembly work. It was one fresh `exec-image` declaration export:

- `nativeImageBodyChange` completed in `22.11s`.
- The changed module export spent `20.863s` in `fresh-export export=nativeImageProjectModuleNamedDeclsText`.
- Total native-image rebuild trace time was `21.974s`.

The follow-up guarded probe `native-incremental-in-process-decls-safe-1` ran the same scenario after making the changed-declaration export path honor `CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS=0` and making the managed verifier defaults use that in-process route under the bounded compiler cap:

- `nativeImageCold` completed in `22.91s`.
- `nativeImageBodyChange` completed in `1.44s`.
- `checkCold` completed in `21.78s`.
- `checkBodyChange` completed in `0.54s`.
- The changed module export spent `0.324s` in `decl-cache-export export=nativeImageProjectModuleNamedDeclsText mode=in-process`.
- Total native-image rebuild trace time was `1.405s`.

Latest interface-indexed build-plan cache capture date: `2026-05-31` (UTC).

The managed probe `.clasp-loops/native-incremental-interface-index.json` ran:

```bash
bash scripts/measure-native-incremental.sh --scenario native-cli-body-change --assert --report .clasp-loops/native-incremental-interface-index.json
```

- The assertion passed with no cache-behavior mismatches.
- `nativeImageCold` completed in `22.55s`.
- `nativeImageBodyChange` completed in `1.55s`.
- `checkCold` completed in `21.34s`.
- `checkBodyChange` completed in `0.54s`.
- The body-change native-image trace now reports `buildPlan = "hit"` through an interface-indexed cache candidate instead of a source-fingerprint-keyed miss.
- The changed module export still correctly missed only for `Shared.User`; `Shared.Render` and `Main` remained decl-module hits.

The same cache path now covers the self-host promotion-style `exec-image nativeImageProjectText --project-entry=...` flow. The managed probe `.clasp-loops/selfhost-incremental-interface-index.json` ran:

```bash
bash scripts/measure-native-incremental.sh --scenario selfhost-body-change --assert --report .clasp-loops/selfhost-incremental-interface-index.json --max-duration checkBodyChange=3 --max-duration imageBodyChange=5
```

- The assertion passed with no cache-behavior mismatches.
- `imageCold` completed in `22.41s`.
- `checkCold` completed in `0.93s` with the shared promoted/incremental cache already warm.
- `checkBodyChange` completed in `0.62s`.
- `imageBodyChange` completed in `1.35s`.
- The body-change self-host image trace reports `buildPlan = "hit"`, `Helper` as the only changed decl-module miss, and `Main` as a decl-module hit.
- `scripts/test-selfhost.sh` now requires the selfhost body-change check path to stay under `CLASP_TEST_SELFHOST_INCREMENTAL_CHECK_BODY_CHANGE_MAX_SECONDS` (default `5s`) and the selfhost body-change image path to stay under `CLASP_TEST_SELFHOST_INCREMENTAL_IMAGE_BODY_CHANGE_MAX_SECONDS` (default `15s`), so the old ~`20s` body-change image cliff is covered by the normal selfhost gate.

Latest compiler export-host cache-root reuse capture date: `2026-05-31` (UTC).

The managed trace `.clasp-loops/cold-check-trace.f7p7Cd/check.log` showed the remaining focused cold check cost is the first compiler export-host load:

- The compiler export host loaded `embedded.compiler.native.image.json` in `20141ms`.
- The three `checkProjectModuleSummaryText` dispatches after load took `18ms`, `24ms`, and `23ms`.
- Repeated checks across isolated `XDG_CACHE_HOME` roots were paying the same first-load cost again even when the compiler image bytes and `claspc` binary were identical.

Compiler native export-host sockets are now content-scoped for compiler images by default, while `CLASP_NATIVE_EXPORT_HOST_COMPILER_CONTENT_SCOPE=0` restores old cache-root scoping. The scenario gate `scripts/test-native-export-host-content-scope.sh` warms the compiler host through one `XDG_CACHE_HOME`, then runs the same compiler export through a second `XDG_CACHE_HOME` and requires the second export to complete under `CLASP_TEST_NATIVE_EXPORT_HOST_CONTENT_SCOPE_SECOND_MAX_SECONDS` (default `5s`).

Latest compiler export-host first-load capture date: `2026-05-31` (UTC).

The guarded forced-fresh host probe `focused-export-host-first-load-measure-2` ran with `CLASP_NATIVE_EXPORT_HOST_COMPILER_CONTENT_SCOPE=0` and `CLASP_NATIVE_EXPORT_HOST_IDLE_TIMEOUT_SECS=1` to avoid reusing an already-warm content-scoped host:

- The compiler export host loaded `embedded.compiler.native.image.json` in `651ms`.
- The full fresh `checkSourceText` export command completed in `1.09s` real time.
- The speed change came from loading native-image JSON arrays in one pass instead of repeatedly rescanning arrays by index while constructing runtime bindings, exports, entrypoints, ABI schemas, route boundaries, and interpreted declarations.

Latest post-array-scan incremental capture date: `2026-05-31` (UTC).

The guarded probes `.clasp-loops/native-incremental-array-scan.json` and `.clasp-loops/selfhost-incremental-array-scan.json` ran after the single-pass native-image loader change:

- Native CLI body-change scenario:
  - `nativeImageCold` completed in `3.45s`.
  - `nativeImageBodyChange` completed in `1.50s`.
  - `checkCold` completed in `1.41s`.
  - `checkBodyChange` completed in `0.61s`.
- Selfhost body-change scenario:
  - `imageCold` completed in `2.63s`.
  - `imageBodyChange` completed in `1.37s`.
  - `checkCold` completed in `0.89s`.
  - `checkBodyChange` completed in `0.50s`.
- Both probes passed cache-behavior assertions and kept body-change image rebuilds on the interface-indexed build-plan hit path.

Latest large compiler-module body-change capture date: `2026-06-01` (UTC).

The guarded probe `.clasp-loops/selfhost-compiler-module-check-speed-proof.json` ran after making the full compiler native-image diagnostic opt-in for this scenario:

```bash
env CLASP_NATIVE_INCREMENTAL_COMPILER_MODULE_IMAGE_PROBE=0 \
  bash scripts/measure-native-incremental.sh \
    --scenario selfhost-compiler-module-body-change \
    --assert \
    --report .clasp-loops/selfhost-compiler-module-check-speed-proof.json \
    --max-duration compilerCheckBodyChange=10
```

- The assertion passed with no cache-behavior mismatches.
- `compilerCheckCold` completed in `5.64s`.
- `compilerCheckBodyChange` completed in `7.89s`.
- The body-change check trace reports `Compiler.Ast` as a `validated-hit` and all other compiler modules, including `CompilerMain`, as cache hits.
- The report records `compilerModuleImageProbe = "skipped"` because the cold full-compiler `nativeImageProjectText` diagnostic is now explicit opt-in via `CLASP_NATIVE_INCREMENTAL_COMPILER_MODULE_IMAGE_PROBE=1`. This avoids putting multi-gigabyte cold native-image runs in normal loops.

Latest affected-verification routing capture date: `2026-05-31` (UTC).

The previous affected run for this file selected `verify-fast` only because `docs/iteration-speed-loop-evidence.md` had no focused route. That fallback cost `277.095s` inside `verify-affected-file-byte-cache-safe-1`.

The affected verifier now routes this iteration-speed evidence document to:

```bash
bash scripts/test-native-incremental-guard.sh
```

The plan-only proof for the current route selected one command, reported `verificationFallbackMode = "none"`, and set `usedVerifyFastFallback = false`.

The guarded affected run `verify-affected-iteration-speed-doc-route-safe-1` passed `7` focused commands in `66.892s`. The iteration-speed evidence route itself ran `bash scripts/test-native-incremental-guard.sh` in `0.841s`; the rest of the time came from verifier-regression and capability-audit coverage for the verifier/audit source changes in the same slice.

## Structural Win

The old default loop rebuilt a fresh hosted native image even in `fast` mode before it did any lighter checks.

The new split removes that rebuild from the default path:

- `fast` is now a check-oriented loop
- `full` remains the rebuild-and-compare loop

That is a real workflow win for repeated compiler edits because the default path no longer pays the full hosted image rebuild up front.

The promoted module-summary seed is a second structural win: a fresh checkout or fresh cache can hydrate normal module-summary cache entries for unchanged promoted self-host modules without re-running the slow semantic checker for those modules. This specifically addresses the verifier-blocking `src/Main.clasp` check path.

The native CLI now also memoizes image and launcher file bytes inside a single `claspc` process while computing cache keys. The affected cache paths still include the original file bytes in their fingerprints, but repeated native-image, source-export, module-summary, and run-binary cache-key calculations no longer reread the same large image or executable from disk within one invocation.

Changed-declaration native-image exports can use the in-process export path under the managed verifier's bounded memory cap. That removes the per-changed-module fresh-process startup cost from focused verify and affected verify while still leaving `CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS=1` available for isolation-heavy runs. Persistent swarm, Codex-loop, autopilot, and self-host promotion launchers default back to fresh worker processes because their long-lived or high-amplitude shape makes memory isolation more important than squeezing every rebuild second out of one compiler process.

Native-image build-plan cache entries still keep source fingerprints in the primary cache key to avoid stale source reuse, but writes also update a bounded interface index keyed by compiler image bytes plus module paths/names. A body-only source edit can therefore find a previous plan candidate, validate every changed source against the cached conservative interface fingerprint, and reuse the plan only when the module surface is unchanged. Interface-changing edits keep missing the indexed candidate and fall back to the normal safe path.

Compiler-image native export-host socket paths are now keyed by `claspc` bytes plus compiler-image bytes instead of by the caller's cache root. Isolated agent workspaces and tests can keep independent artifact caches without forcing another compiler-host image load when they use the same compiler image.

Native-image JSON loading now materializes array item slices in one pass for hot compiler-image sections. This removes the previously measured quadratic rescanning in the first compiler export-host load path.

The affected verifier now has an explicit iteration-speed evidence route, so documentation-only updates to this speed log exercise the native incremental guard instead of paying the broad `verify-fast` fallback.

Large compiler-module body-change checks are also covered by a bounded default scenario. The full compiler native-image version remains available as an opt-in diagnostic, but the default verifier path does not launch it.

The gate for this behavior is permanent in the normal verification path:

- `scripts/verify-all.sh` runs `bash scripts/test-selfhost.sh`
- `scripts/test-selfhost.sh` runs `node scripts/generate-promoted-module-summary-cache.mjs --check`
- `scripts/test-selfhost.sh` checks fresh-cache `src/Main.clasp`
- `scripts/test-selfhost.sh` requires promoted hits for `Compiler.Ast`, `Compiler.Emit.JavaScript`, and `Main`

## Limits

- The March timing numbers are lower bounds because both exact hot-path commands were still running when I stopped the capture on this host.
- The promoted seed is a strong win for unchanged promoted self-host modules. It is not a full solution for arbitrary edits to large compiler modules.
- If a large seeded module changes, its source fingerprint changes and the current checker can still fall back to expensive semantic work for that module.
- In-process file-byte memoization removes redundant file reads during a single compiler invocation.
- In-process changed-decl export and interface-indexed build-plan reuse remove the previously measured `21.11s` native-image body-change cliff for the small focused probe, but true cold native-image and check paths are still around `22s` for that probe.
- Compiler export-host content scoping removes repeated first-load penalties when isolated cache roots use the same compiler image, and single-pass native-image array loading cuts the forced-fresh first compiler-host load to `651ms` on this host.
- The focused native CLI and selfhost cold/body-change probes are now all under `4s` on this host after the array-scan fix.
- The real `Compiler.Ast` body-change check proof is under `8s` on this host and stays within managed memory bounds; the full compiler native-image proof is intentionally not a default loop step.
- The focused iteration-speed evidence route reduces verifier overhead for this doc, but it does not change the compiler hot path itself.
- The next speed slice should reduce and prove the same behavior for more large real compiler modules, especially `Compiler.Checker`, `Compiler.Emit.JavaScript`, `Compiler.Project`, and `Compiler.SemanticArtifacts`.
