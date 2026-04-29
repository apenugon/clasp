#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
tmp_root="$(mktemp -d)"
binary_path="$tmp_root/legal-assistant-upload"
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

  claspc --json check examples/legal-assistant-upload/Main.clasp | grep -F '"status":"ok"' >/dev/null
  env RUSTC=/definitely-missing-rustc claspc compile examples/legal-assistant-upload/Main.clasp -o "$binary_path" >/dev/null

  sample_output="$("$binary_path")"
  printf '%s\n' "$sample_output" | grep -F '"$tag":"Accepted"' >/dev/null
  printf '%s\n' "$sample_output" | grep -F '"documentId":"doc-service-agreement"' >/dev/null
  printf '%s\n' "$sample_output" | grep -F '"raw":"@document[doc-service-agreement|Service Agreement]"' >/dev/null

  route_output="$("$binary_path" route POST /documents/ingest '{"upload":{"documentId":"doc-alpha","filename":"alpha.txt","mediaType":"text/plain","sizeBytes":0,"contentText":"Alpha agreement terms."},"prompt":"Compare @document[doc-alpha|Alpha Agreement] with @document[doc-beta]."}')"
  printf '%s\n' "$route_output" | grep -F '"$tag":"Accepted"' >/dev/null
  printf '%s\n' "$route_output" | grep -F '"documentId":"doc-alpha"' >/dev/null
  printf '%s\n' "$route_output" | grep -F '"raw":"@document[doc-beta]"' >/dev/null

  route_error="$("$binary_path" route POST /documents/ingest '{"upload":{"documentId":"doc-bad","filename":"bad.txt","mediaType":"text/plain","sizeBytes":0,"contentText":"bad"},"prompt":"Broken @document[doc-bad"}')"
  printf '%s\n' "$route_error" | grep -F '"$tag":"Rejected"' >/dev/null
  printf '%s\n' "$route_error" | grep -F 'unterminated @document reference' >/dev/null

  server_port="$(node -e 'const net=require("node:net"); const server=net.createServer(); server.listen(0, "127.0.0.1", () => { console.log(server.address().port); server.close(); });')"
  server_addr="127.0.0.1:$server_port"
  "$binary_path" serve "$server_addr" >/dev/null 2>&1 &
  server_pid=$!

  for _ in $(seq 1 50); do
    if curl -sS -o /dev/null "http://$server_addr/documents/ingest" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done

  served_output="$(curl -sS -X POST -H 'content-type: application/json' \
    --data '{"upload":{"documentId":"doc-http","filename":"http.txt","mediaType":"text/plain","sizeBytes":0,"contentText":"HTTP agreement."},"prompt":"Review @document[doc-http|HTTP Agreement]."}' \
    "http://$server_addr/documents/ingest")"
  printf '%s\n' "$served_output" | grep -F '"$tag":"Accepted"' >/dev/null
  printf '%s\n' "$served_output" | grep -F '"documentId":"doc-http"' >/dev/null

  invalid_status="$(curl -sS -o "$server_body" -w '%{http_code}' -X POST -H 'content-type: application/json' \
    --data '{"upload":{"documentId":"doc-over","filename":"oversize.txt","mediaType":"text/plain","sizeBytes":70000,"contentText":""},"prompt":"Review @document[doc-over]."}' \
    "http://$server_addr/documents/ingest")"
  printf '%s\n' "$invalid_status" | grep -F '200' >/dev/null
  grep -F '"$tag":"Rejected"' "$server_body" >/dev/null
  grep -F 'native ingestion byte limit' "$server_body" >/dev/null

  printf '%s\n' '{"status":"ok","implementation":"clasp-native","example":"legal-assistant-upload"}'
}

if [[ -n "${IN_NIX_SHELL:-}" ]]; then
  run_verify
else
  nix develop "$project_root" --command bash -lc "
    set -euo pipefail
    export CLASP_PROJECT_ROOT=\"$project_root\"
    bash examples/legal-assistant-upload/scripts/verify.sh
  "
fi
