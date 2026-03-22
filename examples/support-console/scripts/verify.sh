#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
tmp_root="$(mktemp -d)"
binary_path="$tmp_root/support-console"
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

  claspc --json check examples/support-console/Main.clasp | grep -F '"status":"ok"' >/dev/null
  env RUSTC=/definitely-missing-rustc claspc compile examples/support-console/Main.clasp -o "$binary_path" >/dev/null

  "$binary_path" route GET /support/customer '{}' | grep -F '"contactEmail":"ops@northwind.example"' >/dev/null
  "$binary_path" route GET /support/customer/page '{}' | grep -F '"title":"Customer export"' >/dev/null

  support_server_port="$(python - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
  support_server_addr="127.0.0.1:$support_server_port"
  "$binary_path" serve "$support_server_addr" >/dev/null 2>&1 &
  server_pid=$!

  for _ in $(seq 1 50); do
    if curl -sS -o /dev/null "http://$support_server_addr/support" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done

  curl -sS "http://$support_server_addr/support" | grep -F '"title":"Support console"' >/dev/null
  curl -sS "http://$support_server_addr/support/customer/page" | grep -F '"title":"Customer export"' >/dev/null
  curl -sS -o "$server_body" -X POST \
    -H 'content-type: application/x-www-form-urlencoded' \
    --data 'customerId=cust-42&summary=Renewal+is+blocked+on+legal+review.' \
    "http://$support_server_addr/support/preview" >/dev/null
  grep -F 'Thanks for the update. Renewal is blocked on legal review. We will send the next renewal step today.' "$server_body" >/dev/null

  printf '%s\n' '{"status":"ok","implementation":"clasp-native","example":"support-console"}'
}

if [[ -n "${IN_NIX_SHELL:-}" ]]; then
  run_verify
else
  nix develop "$project_root" --command bash -lc "
    set -euo pipefail
    export CLASP_PROJECT_ROOT=\"$project_root\"
    bash examples/support-console/scripts/verify.sh
  "
fi
