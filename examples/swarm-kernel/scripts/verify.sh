#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
claspc_bin="${CLASP_CLASPC:-$project_root/runtime/target/debug/claspc}"
test_root="$(mktemp -d)"
binary_path="$test_root/swarm-kernel"
state_root="$test_root/state/root"
event_log="$state_root/events.jsonl"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

if [[ ! -x "$claspc_bin" ]]; then
  cargo build --quiet --manifest-path "$project_root/runtime/Cargo.toml" --bin claspc
fi

CLASP_SWARM_ACTOR=planner "$claspc_bin" compile "$project_root/examples/swarm-kernel/Main.clasp" -o "$binary_path"
[[ -x "$binary_path" ]]

output_path="$(CLASP_SWARM_ACTOR=planner "$binary_path" "$state_root")"
[[ "$output_path" == "$event_log" ]]
[[ -f "$event_log" ]]
grep -F '"kind":"task_created"' "$event_log" >/dev/null
grep -F '"taskId":"bootstrap"' "$event_log" >/dev/null
grep -F '"actor":"planner"' "$event_log" >/dev/null
grep -F '"detail":"Initialize swarm kernel state."' "$event_log" >/dev/null
grep -E '"atMs":[0-9]+' "$event_log" >/dev/null
