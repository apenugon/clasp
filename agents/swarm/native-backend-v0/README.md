# Native Backend Wave v0

This wave starts the full native-backend path rather than another JS-hosted benchmark slice.

The objective is to drive `Clasp` toward the `M10` outcome in the project plan:

- a backend-oriented native IR and runtime ABI exist
- compiler and backend demos can run without Bun
- the same front end and type system drive both JS and native backends

This wave uses canonical backlog task IDs directly.

Lanes in this wave:

- `01-native-ir`
- `02-native-runtime`
- `03-native-codegen`
- `04-native-selfhost`
- `05-native-benchmarks`

Tasks in this wave:

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

- `NB-001` starts immediately.
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

- `Clasp` has a real native execution path below the current lowered IR
- backend and compiler workloads can run without Bun on the native path
- native codegen supports the data and control-flow shapes needed by the current compiler and SaaS app slices
- the self-hosted compiler can execute through the native backend
- the repo has benchmark evidence comparing JS/Bun and native on the same workloads

This wave is expected to be longer-running and less parallel than the recent benchmark-remediation waves because the native backend is mostly one long dependency chain.
