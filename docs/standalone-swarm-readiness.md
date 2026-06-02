standalone-swarm-status: open

# Standalone Swarm Readiness

This file is a canonical repo source surface for Clasp-native swarm improvement tasks.
Local Clasp agents use it with the sibling Clasp, script, and runtime probe files to prove that a standalone swarm can patch existing repo surfaces without Codex-specific control flow.

Required evidence:

- standalone backend policy and capability repair markers are routed to `standalone-swarm`
- planner tasks carry bounded source-edit plans
- local agents edit existing source files through root-confined workspace APIs
- verifiers emit typed gate evidence and source fingerprint postchecks
- `scripts/standalone-swarm-verify.sh --closure --json` validates a candidate workspace plus builder/verifier reports before accepting fixed readiness markers
- closure verification requires a direct-source-edit workspace fingerprint manifest, verifies each target fingerprint against the candidate workspace bytes, cross-checks the Clasp manifest fingerprint claimed by both builder and verifier reports, and emits the manifest SHA-256 in the typed closure report
- `examples/swarm-native/StandaloneSwarmClosureReport.clasp` decodes closure JSON into typed Clasp decisions for managers and planners
- closure decisions classify invalid handoffs into manifest, proof, builder/verifier report, local verifier gate, or verifier-rerun repair kinds so planners can create targeted repair tasks instead of redoing unrelated source edits
- local verifier findings distinguish stale workspace content from standalone source-edit proof or manifest failures
- standalone source-edit findings include concrete issue text and repair hints for missing patch replacements, target postchecks, manifest fingerprints, and proof metadata
- planner retries consume standalone source-edit repair hints and route missing patch replacements, postchecks, proof metadata, or manifest fingerprints to focused repair workers
- managed jobs enforce bounded time, memory, disk, and exact-stop behavior
- `examples/swarm-native/ResourceGuardPolicy.clasp`, `GoalManagerResourceHealth.clasp`, `LocalRouting.clasp`, and `ResourceRecoveryPolicy.clasp` expose, route, preserve, and summarize typed memory-admission, memory-concurrency-admission, and resource-recovery decisions before planners launch more work
