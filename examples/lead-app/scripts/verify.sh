#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
tmp_root="$(mktemp -d)"
binary_path="$tmp_root/lead-app"
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

  claspc --json check examples/lead-app/Main.clasp | grep -F '"status":"ok"' >/dev/null
  env RUSTC=/definitely-missing-rustc claspc compile examples/lead-app/Main.clasp -o "$binary_path" >/dev/null

  lead_create_json="$("$binary_path" route POST /api/leads '{"company":"SynthSpeak API","contact":"Ava Stone","budget":25000,"segment":"Growth"}')"
  printf '%s\n' "$lead_create_json" | grep -F '"leadId":"lead-3"' >/dev/null
  printf '%s\n' "$lead_create_json" | grep -F '"priority":"medium"' >/dev/null
  printf '%s\n' "$lead_create_json" | grep -F '"segment":"growth"' >/dev/null

  lead_server_port="$(node -e 'const net=require("node:net"); const server=net.createServer(); server.listen(0, "127.0.0.1", () => { console.log(server.address().port); server.close(); });')"
  lead_server_addr="127.0.0.1:$lead_server_port"
  "$binary_path" serve "$lead_server_addr" >/dev/null 2>&1 &
  server_pid=$!

  for _ in $(seq 1 50); do
    if curl -sS -o /dev/null "http://$lead_server_addr/api/inbox" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done

  curl -sS "http://$lead_server_addr/api/inbox" | grep -F '"headline":"Priority inbox"' >/dev/null
  created_lead_json="$(curl -sS -X POST -H 'content-type: application/json' \
    --data '{"company":"SynthSpeak API","contact":"Ava Stone","budget":25000,"segment":"Growth"}' \
    "http://$lead_server_addr/api/leads")"
  printf '%s\n' "$created_lead_json" | grep -F '"leadId":"lead-3"' >/dev/null
  curl -sS "http://$lead_server_addr/api/lead/primary" | grep -F '"company":"SynthSpeak API"' >/dev/null
  reviewed_lead_json="$(curl -sS -X POST -H 'content-type: application/json' \
    --data '{"leadId":"lead-3","note":"Schedule technical discovery"}' \
    "http://$lead_server_addr/api/review")"
  printf '%s\n' "$reviewed_lead_json" | grep -F '"reviewNote":"Schedule technical discovery"' >/dev/null

  invalid_budget_status="$(curl -sS -o "$server_body" -w '%{http_code}' -X POST -H 'content-type: application/json' \
    --data '{"company":"Bad Budget Co","contact":"Casey","budget":"oops","segment":"Growth"}' \
    "http://$lead_server_addr/api/leads")"
  printf '%s\n' "$invalid_budget_status" | grep -F '400' >/dev/null
  grep -F 'budget must be an integer' "$server_body" >/dev/null

  unknown_lead_status="$(curl -sS -o "$server_body" -w '%{http_code}' -X POST -H 'content-type: application/json' \
    --data '{"leadId":"lead-404","note":"Missing"}' \
    "http://$lead_server_addr/api/review")"
  printf '%s\n' "$unknown_lead_status" | grep -F '502' >/dev/null
  grep -F 'Unknown lead: lead-404' "$server_body" >/dev/null

  printf '%s\n' '{"status":"ok","implementation":"clasp-native","example":"lead-app"}'
}

if [[ -n "${IN_NIX_SHELL:-}" ]]; then
  run_verify
else
  nix develop "$project_root" --command bash -lc "
    set -euo pipefail
    export CLASP_PROJECT_ROOT=\"$project_root\"
    bash examples/lead-app/scripts/verify.sh
  "
fi
