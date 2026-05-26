#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
test_root="$(mktemp -d "$tmp_root/test-benchmark-prep-cache.XXXXXX")"
task_id="clasp-prep-cache-fixture"
task_dir="$project_root/benchmarks/tasks/$task_id"
workspace_one="$test_root/workspace-one"
workspace_two="$test_root/workspace-two"
workspace_three="$test_root/workspace-three"
cache_root="$test_root/cache"

cleanup() {
  rm -rf "$task_dir" "$test_root"
}

trap cleanup EXIT

rm -rf "$task_dir"
mkdir -p "$task_dir/repo"

cat >"$task_dir/task.json" <<'JSON'
{
  "id": "clasp-prep-cache-fixture",
  "title": "Clasp prep cache fixture",
  "suite": "harness-regression",
  "language": "clasp",
  "repo": "repo",
  "prompt": "prompt.raw.md",
  "defaultBenchmarkPath": true,
  "prepare": [],
  "verify": ["node", "-e", "process.exit(0)"]
}
JSON

cat >"$task_dir/prompt.raw.md" <<'EOF'
Tiny prep cache fixture.
EOF

cat >"$task_dir/repo/Main.clasp" <<'EOF'
module Main

record CacheShape = { label : Str }

main : Str
main = encode (CacheShape { label = "cache-one" })
EOF

CLASP_BENCHMARK_PREP_CACHE_ROOT="$cache_root" \
CLASP_BENCHMARK_PREP_CACHE_TRACE=1 \
  node "$project_root/benchmarks/run-benchmark.mjs" prepare "$task_id" --workspace "$workspace_one" \
  >"$test_root/first.out" 2>"$test_root/first.err"

grep -F '[benchmark-prep-cache] miss ' "$test_root/first.err" >/dev/null
grep -F '[benchmark-prep-cache] saved ' "$test_root/first.err" >/dev/null
test -f "$workspace_one/benchmark-prep/Main.context.json"
test -f "$workspace_one/benchmark-prep/Main.agent-pack.json"
test -f "$workspace_one/LANGUAGE_GUIDE.md"

CLASP_BENCHMARK_PREP_CACHE_ROOT="$cache_root" \
CLASP_BENCHMARK_PREP_CACHE_TRACE=1 \
  node "$project_root/benchmarks/run-benchmark.mjs" prepare "$task_id" --workspace "$workspace_two" \
  >"$test_root/second.out" 2>"$test_root/second.err"

grep -F '[benchmark-prep-cache] hit ' "$test_root/second.err" >/dev/null
cmp -s "$workspace_one/benchmark-prep/Main.context.json" "$workspace_two/benchmark-prep/Main.context.json"
cmp -s "$workspace_one/benchmark-prep/Main.agent-pack.json" "$workspace_two/benchmark-prep/Main.agent-pack.json"
cmp -s "$workspace_one/LANGUAGE_GUIDE.md" "$workspace_two/LANGUAGE_GUIDE.md"

cat >"$task_dir/repo/Main.clasp" <<'EOF'
module Main

record CacheShape = { label : Str, count : Int }

main : Str
main = encode (CacheShape { label = "cache-two", count = 2 })
EOF

CLASP_BENCHMARK_PREP_CACHE_ROOT="$cache_root" \
CLASP_BENCHMARK_PREP_CACHE_TRACE=1 \
  node "$project_root/benchmarks/run-benchmark.mjs" prepare "$task_id" --workspace "$workspace_three" \
  >"$test_root/third.out" 2>"$test_root/third.err"

grep -F '[benchmark-prep-cache] miss ' "$test_root/third.err" >/dev/null
grep -F '[benchmark-prep-cache] saved ' "$test_root/third.err" >/dev/null
if cmp -s "$workspace_one/benchmark-prep/Main.context.json" "$workspace_three/benchmark-prep/Main.context.json"; then
  echo "expected changed task source to invalidate the prep cache" >&2
  exit 1
fi

printf 'test-benchmark-prep-cache: ok\n'
