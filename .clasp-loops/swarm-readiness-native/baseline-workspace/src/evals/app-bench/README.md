# App-Bench Seed

This directory vendors the public `App-Bench` dataset snapshot and records the first task Clasp should optimize toward.

Upstream sources:

- Benchmark site: `https://appbench.ai/`
- Dataset: `https://huggingface.co/datasets/AfterQuery/App-Bench`

Local snapshot:

- `vendor/app-bench/AppBench vExternal.csv`

The upstream dataset currently includes six app-building tasks:

- Financial Dashboard
- Hospital Dashboard
- Legal Assistant
- Pharmacy System
- Drawing Game
- Rental Booking

## Chosen First Target

The recommended first target is `Legal Assistant`.

Rationale:

- It best matches Clasp's current strengths around typed boundaries, AI/tool integration, retrieval, auth, storage, and policy-sensitive application logic.
- It is still clearly full-stack, but it avoids the heaviest realtime/game/media burdens from some of the other tasks.
- It is a stronger test of compiler-known seams than a mostly visual or multiplayer-first app.

See [legal-assistant.md](/home/akul_medexfinance_com/clasp/src/evals/app-bench/legal-assistant.md) for the concrete benchmark slice and why it should show language leverage.
