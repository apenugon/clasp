#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
tmp_root="$(mktemp -d)"
binary_path="$tmp_root/release-gate"
server_headers="$tmp_root/server-headers.txt"
server_body="$tmp_root/server-body.json"
server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp_root"
}

trap cleanup EXIT

run_verify() {
  cd "$project_root"

  claspc --json check examples/release-gate/Main.clasp | grep -F '"status":"ok"' >/dev/null
  env RUSTC=/definitely-missing-rustc claspc compile examples/release-gate/Main.clasp -o "$binary_path" >/dev/null

  "$binary_path" route GET /release/audit '{}' | grep -F '"status":{"$tag":"Pending"}' >/dev/null

  release_server_port="$(python - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
  release_server_addr="127.0.0.1:$release_server_port"
  "$binary_path" serve "$release_server_addr" >/dev/null 2>&1 &
  server_pid=$!

  for _ in $(seq 1 50); do
    if curl -sS -o /dev/null "http://$release_server_addr/release-gate" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done

  curl -sS "http://$release_server_addr/release-gate" | grep -F '"title":"Release gate"' >/dev/null
  curl -sS -o "$server_body" -X POST \
    -H 'content-type: application/x-www-form-urlencoded' \
    --data 'releaseId=rel-204&summary=Ship+the+support+automation+pipeline.' \
    "http://$release_server_addr/release/review" >/dev/null
  grep -F 'Approved after typed policy review.' "$server_body" >/dev/null
  curl -sS -D "$server_headers" -o "$server_body" -X POST \
    "http://$release_server_addr/release/accept" >/dev/null
  grep -F 'HTTP/1.1 303 See Other' "$server_headers" >/dev/null
  grep -Fi 'Location: /release/ack' "$server_headers" >/dev/null

  printf '%s\n' '{"status":"ok","implementation":"clasp-native","example":"release-gate"}'
}

if [[ -n "${IN_NIX_SHELL:-}" ]]; then
  run_verify
else
  nix develop "$project_root" --command bash -lc "
    set -euo pipefail
    export CLASP_PROJECT_ROOT=\"$project_root\"
    bash examples/release-gate/scripts/verify.sh
  "
fi
