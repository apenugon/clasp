pub const STANDALONE_SWARM_STATUS: &str = "open";

pub const STANDALONE_SWARM_REQUIRED_SURFACES: &[&str] = &[
    "src/StandaloneSwarmReadiness.clasp",
    "src/StandaloneSwarmVerifier.clasp",
    "examples/swarm-native/StandaloneSwarmHarness.clasp",
    "examples/swarm-native/StandaloneSwarmRouting.clasp",
    "examples/swarm-native/StandaloneSwarmClosureReport.clasp",
    "examples/swarm-native/StandaloneSwarmClosureReportHarness.clasp",
    "scripts/standalone-swarm-readiness.sh",
    "scripts/standalone-swarm-verify.sh",
    "docs/standalone-swarm-readiness.md",
    "runtime/standalone_swarm_probe.rs",
];

pub fn standalone_swarm_probe_summary() -> String {
    format!(
        "standalone-swarm={} surfaces={}",
        STANDALONE_SWARM_STATUS,
        STANDALONE_SWARM_REQUIRED_SURFACES.len()
    )
}
