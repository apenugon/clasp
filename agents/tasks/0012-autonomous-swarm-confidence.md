# 0012 Autonomous Swarm Confidence

## Goal

Make Clasp strong enough that we can honestly trust an autonomous self-improving swarm implemented in Clasp itself to run for real language/runtime/compiler improvement work with minimal human intervention.

## Architectural Direction

- A swarm, agent, planner, verifier, or loop is an ordinary Clasp program.
- The system must be startable with `claspc run <program>`.
- Do not require shell wrapper orchestration as the primary execution model.
- Do not rely on `claspc swarm ...` as the primary model.

## Required Capabilities

- Ordinary-program autonomy:
  - the builder/verifier loop runs as a normal Clasp program
  - direct Codex invocation happens from Clasp
  - durable state records final pass/fail status, progress, retries, and recovery
  - a live loop can continue through multiple attempts without shell supervision
- Durable orchestration substrate:
  - objective/run/task/event/artifact persistence
  - DAG/task dependency tracking and projected readiness
  - lease ownership, expiry, reclaim, and recovery
  - approval and merge-policy state
  - tool/process execution from Clasp
  - monitoring/state inspection sufficient for a live autonomous run
- Autonomous viability:
  - no obvious missing runtime/control-plane substrate still forces the real orchestration logic back into shell glue
  - the verifier can justify that the system is ready for autonomous improvement work, not merely supervised demos
  - failure handling and retry semantics are strong enough that the loop can survive ordinary transient errors
- Language/runtime ergonomics:
  - Dict-capable state handling
  - coherent empty-list and polymorphic collection behavior
  - usable record update/destructuring for orchestration state
  - no clear ergonomic blocker that would make serious autonomous swarm logic impractical
- Verification:
  - scenario-level or end-to-end coverage for the ordinary-program loop path
  - scenario-level or end-to-end coverage for new runtime/workflow/control-plane behavior
  - `bash scripts/verify-all.sh` passes before the verifier can return `pass`

## Acceptance

- The verifier can honestly conclude that Clasp is ready for an autonomous self-improving swarm implemented in Clasp itself, not only a supervised or demo-quality loop.
- The verifier must evaluate the whole repository against the required capabilities above, not only the latest narrow diff.
- The verifier must fail if any required capability is still missing, only scaffolded, or validated only by shallow/demo behavior.
- `bash scripts/verify-all.sh` passes.

## Notes

- Do not optimize for a shallow local pass.
- Prefer closing whole capability categories over superficial harness-only fixes.
- If autonomous confidence is not yet justified, the verifier should fail and force another builder attempt.
