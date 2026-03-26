# 0010 Iteration Speed Loop

## Goal

Make Clasp materially faster to iterate on, with the highest priority on self-hosted compiler rebuild and promotion latency.

## Scope

- Focus only on iteration speed and developer feedback-loop latency.
- Prefer structural improvements over micro-optimizations.
- Keep narrowing the hot path for:
  - self-hosted `claspc check src/Main.clasp`
  - self-hosted `nativeImageProjectText`
  - `src/scripts/verify.sh`
  - `scripts/verify-all.sh` where the slowness is caused by self-hosted compiler work

## Required Work

- Measure before/after timings for the exact hot paths being targeted.
- Prefer changes like:
  - smaller dedicated compiler entrypoints
  - reduced compiler import closure
  - module/interface semantic caching
  - source-export caching
  - fast-vs-full verification architecture
  - better invalidation boundaries in hot compiler modules
- Keep any speedup changes correct on the self-hosted/native path.

## Constraints

- Do not broaden scope into unrelated swarm feature work unless it directly improves iteration speed.
- Do not declare success based only on a small example project if the self-hosted compiler hot path is still bad.
- If a change only helps warm cache cases, say so explicitly.

## Acceptance

- The verifier can honestly conclude that iteration speed has improved enough that Clasp can be used more effectively to improve itself.
- There is at least one concrete measured win on a real self-hosted hot path.
- The task leaves behind a clear path for the next speed slice if the full problem is not solved.
- `bash scripts/verify-all.sh` passes on the resulting tree.

## Notes

- The main bottleneck to attack is self-hosted compiler latency, not frontend polish or generic code cleanup.
- Favor changes that reduce repeated semantic work over changes that merely shuffle shell scripts around.
