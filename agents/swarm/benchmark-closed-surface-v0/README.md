# Benchmark Closed-Surface Wave v0

This wave is the next narrow pass aimed at removing runtime, generated-output, and test-surface leakage from the `Clasp` benchmark app path.

The immediate objective is:

- make ordinary benchmark product changes stay inside compiler-known app declarations plus generated fixture or binding surfaces
- stop rewarding edits to runtime wrappers or brittle test assertions just to satisfy page metadata or host-binding details
- make the benchmark workspace self-describing from compiler-owned semantic artifacts rather than ad hoc repo archaeology

This wave uses canonical backlog task IDs directly.

Lanes in this wave:

- `01-page-projections`
- `02-host-surface`
- `03-benchmark-surface`

Tasks in this wave:

- `FS-017` page-render projection split between stable SSR HTML and machine metadata
- `FS-018` generated typed host-binding adapters
- `FS-019` compiler-owned seeded fixture and mock-boundary declarations
- `BM-022` semantic benchmark acceptance helpers and mutation-surface guards
- `BM-023` benchmark-prep semantic packs and generated workspace guidance

Dependency flow:

- `FS-017` starts immediately.
- `FS-018` builds on `FS-017`.
- `FS-019` builds on `FS-018`.
- `BM-022` depends on `FS-017`, `FS-019`, `FS-015`, and `CP-013`.
- `BM-023` depends on `BM-022`, `CP-013`, `FS-015`, and `TY-015`.

Success for this wave means:

- the default `Clasp` page HTML is stable enough that benchmark tasks do not need runtime or test edits just to ignore machine metadata
- benchmark-facing host bindings are generated and typed enough that product-field changes stop leaking into imperative JSON glue
- benchmark task repos can carry seeded fixtures and mock boundaries through compiler-owned declarations instead of hand-maintained host code
- benchmark prep writes a semantic pack and local guidance from compiler artifacts before the agent starts exploring
- the next `Raw Repo` and `File-Hinted` reruns can credibly measure the language surface instead of runtime-wrapper and test-brittleness noise
