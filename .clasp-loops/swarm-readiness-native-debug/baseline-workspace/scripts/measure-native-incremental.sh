#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
claspc_bin="$project_root/runtime/target/debug/claspc"
time_bin="$(which time)"
probe_root="$(mktemp -d)"
project_dir="$probe_root/body-cache-project"
cache_root="$probe_root/cache"

cleanup() {
  rm -rf "$probe_root"
}

trap cleanup EXIT

if [[ ! -x "$claspc_bin" ]]; then
  printf 'missing native claspc binary at %s\n' "$claspc_bin" >&2
  exit 1
fi

if [[ -z "$time_bin" || ! -x "$time_bin" ]]; then
  printf 'missing time binary\n' >&2
  exit 1
fi

mkdir -p "$project_dir/Shared" "$cache_root"

cat >"$project_dir/Main.clasp" <<'EOF'
module Main

import Shared.User
import Shared.Render

main : Str
main = renderUser defaultUser
EOF

cat >"$project_dir/Shared/User.clasp" <<'EOF'
module Shared.User

record User = { name : Str }

defaultUser : User
defaultUser = User { name = "planner" }
EOF

cat >"$project_dir/Shared/Render.clasp" <<'EOF'
module Shared.Render

import Shared.User

renderUser : User -> Str
renderUser user = user.name
EOF

"$time_bin" -p -o "$probe_root/first.time" \
  env XDG_CACHE_HOME="$cache_root" CLASP_NATIVE_TRACE_CACHE=1 \
  "$claspc_bin" native-image "$project_dir/Main.clasp" -o "$probe_root/first.native.image.json" \
  >/dev/null 2>"$probe_root/first.log"

sed -i 's/planner/operator/' "$project_dir/Shared/User.clasp"

"$time_bin" -p -o "$probe_root/second.time" \
  env XDG_CACHE_HOME="$cache_root" CLASP_NATIVE_TRACE_CACHE=1 \
  "$claspc_bin" native-image "$project_dir/Main.clasp" -o "$probe_root/second.native.image.json" \
  >/dev/null 2>"$probe_root/second.log"

printf 'cold_real=%s\n' "$(sed -n 's/^real //p' "$probe_root/first.time")"
printf 'body_change_real=%s\n' "$(sed -n 's/^real //p' "$probe_root/second.time")"
printf '%s\n' '--- second trace ---'
cat "$probe_root/second.log"
