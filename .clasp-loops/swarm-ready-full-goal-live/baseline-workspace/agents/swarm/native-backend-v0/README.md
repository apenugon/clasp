# Native Backend Wave v0

This wave now includes the full transitive dependency closure for the native backend path instead of a hand-curated subset, plus the explicit foreign-package interop tasks needed to let `Clasp` absorb `npm`, `Python`, and `Rust` ecosystems without giving up compiler ownership.
It also now carries the stricter foreign-boundary typing work needed to reject ambient `Any`, force explicit unsafe refinement for untyped imports, and preserve blame-carrying diagnostics when a foreign value violates the claimed `Clasp` type.

The native goal is still the same:

- define a backend-native IR and runtime ABI
- run compiler and backend workloads without Bun
- keep the same front end and type system across JS and native targets

The difference is that this wave now reflects the actual canonical backlog graph. Reaching the native backend requires most of the roadmap first, including the language floor, type system, schema/runtime boundaries, control plane, workflows, AI platform, SaaS dogfood, and hosted self-hosting path.

This wave therefore snapshots the full closure of dependencies for:

- `NB-001` through `NB-009`
- `BM-014`

And it explicitly carries these interop adoption tasks on top:

- `TY-016`
- `FS-020` through `FS-023`
- `BM-024` through `BM-025`

Current wave size:

- `122` canonical tasks

Lanes in this wave:

- `01-core-language` with `LG-001` through `LG-019`
- `02-type-system` with `TY-001` through `TY-010` plus `TY-016`
- `03-schemas` with `SC-001` through `SC-013`
- `04-full-stack` with `FS-001` through `FS-010` plus `FS-020` through `FS-023`
- `05-control-plane` with `CP-001` through `CP-012`
- `06-workflows` with `WF-001` through `WF-010`
- `07-ai-platform` with `AI-001` through `AI-011`
- `08-saas-dogfood` with `SA-001` through `SA-010`
- `09-self-hosting` with `SH-001` through `SH-010`
- `10-native-backend` with `NB-001` through `NB-009`
- `11-benchmarks` with `BM-014` plus `BM-024` through `BM-025`

Why this shape:

- `SA-001` is blocked by `AI-011` and `FS-010`
- `SH-001` is blocked by `SA-010`
- `NB-001` is blocked by `SH-010`
- `BM-014` is blocked by `NB-008`

So a realistic native wave cannot begin at `NB-*`; it must begin at the earliest unmet work in the language and product stack.

Success for this wave means:

- the full dependency ladder from language floor through hosted self-hosting is complete enough to unlock native work
- `Clasp` has a real native execution path below the current lowered IR
- compiler and backend workloads can run without Bun on the native path
- the self-hosted compiler can execute through the native backend
- the repo has benchmark evidence comparing JS/Bun and native on the same workloads

This wave is expected to be long-running, only partially parallel, and much closer to a whole-roadmap execution program than a narrow feature sprint.
