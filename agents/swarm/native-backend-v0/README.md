# Native Backend Wave v0

This wave starts the full native-backend path from the earliest unmet prerequisite rather than pretending the native tasks can begin in isolation.

The objective is to drive `Clasp` through:

- the remaining hosted self-hosting prerequisite chain
- the native-backend path in `M10`

The native track depends on `SH-010`, so this wave intentionally includes the self-hosting chain needed to unlock it.

The `M10` outcome in the project plan is:

- a backend-oriented native IR and runtime ABI exist
- compiler and backend demos can run without Bun
- the same front end and type system drive both JS and native backends

This wave uses canonical backlog task IDs directly.

Lanes in this wave:

- `01-self-hosting-foundation`
- `02-self-hosting-frontend`
- `03-hosted-self-host`
- `04-native-ir`
- `05-native-runtime`
- `06-native-codegen`
- `07-native-selfhost`
- `08-native-benchmarks`

Tasks in this wave:

- `SH-001` self-hosting subset and bootstrap boundary
- `SH-002` standard-library surface for compiler code written in `Clasp`
- `SH-003` formatter and diagnostics helpers in `Clasp`
- `SH-004` module loading and package resolution in `Clasp`
- `SH-005` parser in `Clasp`
- `SH-006` lowered IR helpers and JavaScript emitter in `Clasp`
- `SH-007` checker and type inference in `Clasp`
- `SH-008` hosted self-hosted compiler through JS/Bun
- `SH-009` stage0/stage1/stage2 bootstrap reproducibility checks
- `SH-010` switch the primary compiler implementation to `Clasp` with Haskell fallback
- `NB-001` backend-native IR below the current lowered IR
- `NB-002` native runtime ABI and data layout
- `NB-003` first native bytecode or native-target IR path
- `NB-004` minimal native runtime for compiler and backend execution
- `NB-005` native code generation for functions, ADTs, records, and control flow
- `NB-006` native JSON and runtime-boundary support for compiler and SaaS workloads
- `NB-007` self-hosted compiler execution through the native backend
- `NB-008` JS/Bun versus native backend benchmarks
- `BM-014` backend compile-time and runtime benchmarks comparing JS/Bun and native
- `NB-009` native support for compiler-owned binary boundary codecs and efficient transport

Dependency flow:

- `SH-001` starts immediately.
- `SH-002` builds on `SH-001`.
- `SH-003` builds on `SH-002`.
- `SH-004` builds on `SH-003`.
- `SH-005` builds on `SH-004`.
- `SH-006` builds on `SH-005`.
- `SH-007` builds on `SH-006`.
- `SH-008` builds on `SH-007`.
- `SH-009` builds on `SH-008`.
- `SH-010` builds on `SH-009`.
- `NB-001` builds on `SH-010`.
- `NB-002` builds on `NB-001`.
- `NB-003` builds on `NB-002`.
- `NB-004` builds on `NB-003`.
- `NB-005` builds on `NB-004`.
- `NB-006` builds on `NB-005`.
- `NB-007` builds on `NB-006`.
- `NB-008` builds on `NB-007`.
- `BM-014` builds on `NB-008`.
- `NB-009` builds on `NB-008`.

Success for this wave means:

- the hosted self-hosted compiler path is complete enough to act as the prerequisite for native work
- `Clasp` has a real native execution path below the current lowered IR
- backend and compiler workloads can run without Bun on the native path
- native codegen supports the data and control-flow shapes needed by the current compiler and SaaS app slices
- the self-hosted compiler can execute through the native backend
- the repo has benchmark evidence comparing JS/Bun and native on the same workloads

This wave is expected to be longer-running and less parallel than the recent benchmark-remediation waves because both the hosted self-hosting and native backend tracks are mostly long dependency chains.
