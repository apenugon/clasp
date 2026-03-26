# Public Benchmark Evidence For Clasp

## Purpose

This note captures what public benchmark evidence would materially increase confidence that `Clasp` is not just an interesting language idea, but a meaningfully better substrate for agent-driven software work.

The claim here is not "prove the full vision completely."
Current public benchmarks are too narrow for that.

It is important to separate two different claims:

- `Adoption wedge claim`: `Clasp` improves agent performance as a semantic control plane or metalanguage over existing repositories written in other languages.
- `Language claim`: software implemented in `Clasp` itself is easier, safer, or more efficient for agents to build and evolve than software implemented in current mainstream languages.

Current public benchmarks are much better for the first claim than the second.

So the practical public-benchmark claim is narrower:

- show that `Clasp` materially improves verified software outcomes on public tasks
- show that it does so with much better token, cost, or time efficiency
- use that as a public wedge to attract contributors before a more Clasp-native benchmark suite exists

## Quantitative Evidence That Would Matter

### 1. `SWE-bench Multilingual`

This is the strongest public benchmark for broad external credibility because it is:

- real repo maintenance work
- multilingual
- already recognized by the agent community
- easy to compare head-to-head with existing agent scaffolds

Convincing evidence here would be one of:

- `60-65%+` resolved on the public benchmark
- or roughly current strong public performance with `5-10x` lower cost or token usage
- or the same resolved rate with materially fewer retries, fewer steps, and better stability

That would be a strong public signal that `Clasp` is helping agents complete real software changes more efficiently across ecosystems rather than only on one language stack.

It does **not** directly test the `Language claim`, because the benchmark repos are written in the supported benchmark languages rather than in `Clasp`.

### 2. `Terminal-Bench`

This is probably the best public fit for the agent-runtime and control-plane side of the thesis.

Convincing evidence here would be one of:

- `10-15` absolute points more task success than a non-`Clasp` scaffold on the same model
- or similar task success with roughly `5x` lower time, turns, or cost
- or a visibly better failure profile on multi-step terminal tasks

This would matter because it is closer than `SWE-bench` to the real "agent operating system" problem.

It still mostly supports the `Adoption wedge claim`, not the full `Language claim`.

### 3. `MCPMark`

This is the best public benchmark for explicit cost and token-efficiency evidence.

Convincing evidence here would be one of:

- `50%+` pass@1 at `<= $25-30` per run
- or `60%+` pass@1 at `<= $50` per run
- or a clearly better pass-rate-versus-cost curve than existing public entries

This would not prove the whole `Clasp` thesis, but it would be the cleanest public proof that the language and control-plane semantics are reducing wasted agent reasoning.

### 4. `App-Bench`

This is useful as supporting evidence for "build a SaaS app" style claims.

Convincing evidence here would be one of:

- `85%+` feature coverage
- or matching the current top tier with materially fewer retries and less prompt churn

This is useful, but it should not be the primary public proof because it is one-shot generation and under-measures replay, verification, migration safety, and control-plane semantics.

## What Public Benchmarks Still Cannot Prove

Even very strong results on the benchmarks above would still under-measure the most differentiated parts of `Clasp`:

- replay and deterministic debugging
- affected-surface verification planning
- workflow upgrade and handoff safety
- capability and policy enforcement
- semantic graph queryability
- faster root-cause isolation after failures

So public benchmarks can prove:

- `Clasp` helps agents do more verified work per token, time, or dollar

But they cannot fully prove:

- the full language and runtime vision is already validated

That still needs a custom `Clasp`-native benchmark suite.

## Best Benchmark By Claim

### Best benchmark for the `Adoption wedge claim`

If the question is:

- can `Clasp` make existing coding agents better on existing repositories?
- can `Clasp` attract attention as a semantic control plane over current stacks?

then the best public benchmark is:

`SWE-bench Multilingual`

Why:

- public and already trusted
- multilingual rather than Python-only
- easy to explain
- easy to compare against current agent scaffolds
- a good fit for a `mini-swe-agent` style baseline

### How `SWE-bench Multilingual` should actually be used

For the clean public comparison, the benchmark tasks and repositories should stay unchanged.

The comparison should be:

- baseline: stock agent scaffold
- variant: the same agent scaffold with a `Clasp` control-plane or semantic layer

In other words:

- modify the agent
- do **not** modify the benchmark samples

That keeps the result legible and directly comparable to public baselines.

If the benchmark samples are edited to add `Clasp` annotations, sidecars, or extra semantic artifacts, then the result is no longer a clean run of the original public benchmark. That can still be useful later, but it becomes a derived benchmark for a different question.

So the practical order should be:

1. run the untouched public benchmark with a `Clasp`-enhanced agent scaffold
2. only later consider a reproducible derived dataset with generated `Clasp` sidecars

### Best benchmark for the `Language claim`

If the question is:

- is software written in `Clasp` itself easier or more efficient for agents to build and evolve?

then none of the existing public benchmarks is a clean fit.

The best answer there is:

- a custom `Clasp`-native benchmark
- ideally built around a small evolving SaaS app or control-plane-heavy product
- with paired tasks also implemented in strong `TypeScript`/`Python` baselines

If forced to use a public benchmark as the nearest proxy, I would choose:

`Terminal-Bench`

because it is the closest to testing the broader agent-runtime and workflow-control problem rather than just repo patching in fixed host languages.

## If Only One Public Benchmark Should Be Prioritized

If the goal is:

- show outsiders there is something real here
- attract contributors
- get a legible public win

then the single best choice is:

`SWE-bench Multilingual`

Why:

- it is already a recognized public benchmark
- it avoids the "this only works on Python" objection
- it is easy to explain to contributors
- it maps cleanly onto a `mini-swe-agent` style baseline
- a win there is easier for outsiders to trust than a custom benchmark

This recommendation is specifically about the `Adoption wedge claim`.

If the goal were instead "best benchmark fit for the deep `Clasp` language/runtime thesis," I would pick `Terminal-Bench`, while still saying that a custom `Clasp`-native benchmark is the real answer.

But if forced to choose only one benchmark for traction and contributor pull, I would choose:

`SWE-bench Multilingual`

## Practical Recommendation

The best sequence is probably:

1. Public traction benchmark: `SWE-bench Multilingual`
2. Better thesis-fit benchmark: `Terminal-Bench`
3. Custom `Clasp`-native benchmark suite for replay, verification, workflow state, policies, and debugging

That order maximizes both public legibility and fidelity to what `Clasp` is actually trying to prove.
