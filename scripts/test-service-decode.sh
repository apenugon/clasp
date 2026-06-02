#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_SERVICE_DECODE_TIMEOUT_SECS:-120}"

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  printf 'CLASP_SERVICE_DECODE_TIMEOUT_SECS must be a positive integer\n' >&2
  exit 1
fi

mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"

grep -F 'match tryDecode WatchedProcess raw' "$project_root/examples/swarm-native/Service.clasp" >/dev/null
grep -F 'match tryDecode ServiceStatus raw' "$project_root/examples/swarm-native/Service.clasp" >/dev/null
grep -F 'match tryDecode ServiceUpgradeTransaction raw' "$project_root/examples/swarm-native/Service.clasp" >/dev/null

if grep -F 'Ok raw -> Ok (decode WatchedProcess raw)' "$project_root/examples/swarm-native/Service.clasp" >/dev/null; then
  printf 'Service still trusts raw watched-process JSON through decode\n' >&2
  exit 1
fi

if [[ "${CLASP_SERVICE_DECODE_RUN_HARNESS:-0}" == "1" ]]; then
  claspc_bin="$("$project_root/scripts/resolve-claspc.sh")"
  output="$(timeout "$timeout_secs" "$claspc_bin" run "$project_root/examples/swarm-native/ServiceDecodeHarness.clasp")"

  grep -F 'watched-valid=ok:7:true' <<<"$output" >/dev/null
  grep -F 'watched-invalid=err:watched process decode failed:' <<<"$output" >/dev/null
  grep -F 'status-invalid=err:service status decode failed:' <<<"$output" >/dev/null
  grep -F 'upgrade-invalid=err:service upgrade decode failed:' <<<"$output" >/dev/null
fi

printf 'service-decode-ok\n'
