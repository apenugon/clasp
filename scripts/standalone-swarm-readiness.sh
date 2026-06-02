#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_file() {
  local relative="$1"
  if [[ ! -f "$project_root/$relative" ]]; then
    printf 'standalone-swarm=missing-surface:%s\n' "$relative"
    exit 1
  fi
}

require_file "src/StandaloneSwarmReadiness.clasp"
require_file "src/StandaloneSwarmVerifier.clasp"
require_file "examples/swarm-native/StandaloneSwarmHarness.clasp"
require_file "examples/swarm-native/StandaloneSwarmRouting.clasp"
require_file "examples/swarm-native/StandaloneSwarmClosureReport.clasp"
require_file "examples/swarm-native/StandaloneSwarmClosureReportHarness.clasp"
require_file "scripts/standalone-swarm-verify.sh"
require_file "docs/standalone-swarm-readiness.md"
require_file "runtime/standalone_swarm_probe.rs"

echo "standalone-swarm=open"
printf 'standalone-swarm-surfaces=src,examples,scripts,docs,runtime\n'
printf 'standalone-swarm-repair-markers=backendConfigRepair=agent-backend,plannerBackendConfigRepair=agent-backend\n'
