# 0009 Swarm Readiness Loop

## Goal

Make Clasp ready for a native builder/verifier swarm that can meaningfully improve Clasp itself.

## Scope

- Keep pushing the native swarm runtime until there is a real objective-driven manager loop rather than only examples and scaffolds
- Add the missing state-heavy language/runtime ergonomics needed to author that swarm comfortably inside Clasp
- Reduce self-hosted iteration pain enough that the swarm can plausibly iterate on the compiler without spending most of its time waiting on rebuilds

## Required Capabilities

- Durable native swarm state:
  - objective/run records
  - task/event/artifact persistence
  - task DAG edges and status projection
  - lease ownership plus expiry/recovery
  - approvals and merge-policy state
- First-class native swarm control:
  - `claspc swarm` commands for at least status, tail, and approve
  - enough manager-side control to inspect and steer a live run
- Swarm authoring ergonomics:
  - a real `Dict` or map-capable state surface
  - ergonomics suitable for state-heavy orchestration code
  - keep empty-list, record, and polymorphic collection behavior coherent while extending this surface
- Verification:
  - add or update scenario-level coverage proving the swarm/runtime surfaces actually work end to end
  - keep the self-hosted path green

## Acceptance

- The verifier can honestly conclude that swarms can be implemented in Clasp well and completely enough to continue building the rest of the system inside Clasp itself
- `bash scripts/verify-all.sh` passes

## Notes

- Do not optimize for a shallow “demo complete” pass.
- The verifier should fail until the runtime, language ergonomics, and control-plane surfaces are genuinely strong enough for serious swarm implementation work.
