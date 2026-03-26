# 0011 Full Swarm-Ready Goal

## Goal

Make Clasp genuinely ready for a serious supervised self-improving swarm implemented in Clasp itself.

## Architectural Direction

- A swarm, agent, or loop is an ordinary Clasp program.
- The system should be startable with `claspc run <program>`.
- Do not rely on `claspc swarm ...` as the primary model.
- Do not require shell wrapper scripts for builder/verifier orchestration.

## Required Capabilities

- Ordinary-program execution model:
  - the builder/verifier loop runs as a normal Clasp program
  - direct Codex invocation happens from Clasp, not from shell wrappers
  - loop state persists in ordinary runtime storage and records final pass/fail state correctly
- Durable native orchestration substrate:
  - objective/run/task/event/artifact persistence
  - task DAG edges and projected status
  - lease ownership, expiry, and recovery
  - approval and merge-policy state
  - tool/process execution from Clasp
  - monitoring/state inspection surfaces sufficient for a live run
- Clasp-native self-improvement viability:
  - enough runtime and control-plane capability that builder/verifier/planner style programs can be written directly in Clasp
  - no obvious missing substrate that still forces the real orchestration logic back out into shell glue
- Language/runtime ergonomics for state-heavy orchestration:
  - `Dict`-capable state handling
  - coherent empty-list behavior
  - coherent polymorphic collection behavior
  - record update/destructuring behavior that is usable for orchestration state
  - no clear ergonomic blocker that would make serious swarm implementation impractical
- Verification:
  - scenario-level or end-to-end coverage for the ordinary-program loop path
  - scenario-level or end-to-end coverage for any new runtime/workflow/control-plane behavior added during the task
  - `bash scripts/verify-all.sh` passes

## Acceptance

- The verifier can honestly conclude that Clasp is ready for a supervised self-improving swarm implemented in Clasp itself, not merely that one recent diff looks acceptable.
- The verifier must evaluate the whole repository against the required capabilities above, not only the narrow latest delta.
- The verifier must fail if any required capability is still missing, only scaffolded, or validated only by shallow/demo behavior.
- `bash scripts/verify-all.sh` passes.

## Notes

- Do not stop at a partial local pass.
- Do not optimize for a demo-only answer.
- If a capability is intentionally deferred, the verifier should still fail until the repository is honestly ready for the full goal above.
