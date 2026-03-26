#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root=""

cleanup() {
  rm -rf "${test_root:-}"
}

trap cleanup EXIT

test_root="$(mktemp -d)"
project_dir="$test_root/project"
workspace_dir="$project_dir/workspace"
runtime_dir="$project_dir/runtime"

mkdir -p \
  "$project_dir/scripts" \
  "$project_dir/agents/schemas" \
  "$project_dir/tools" \
  "$workspace_dir"

cp \
  "$project_root/scripts/clasp-builder.sh" \
  "$project_root/scripts/clasp-codex-home.sh" \
  "$project_root/scripts/clasp-codex-loop.sh" \
  "$project_root/scripts/clasp-codex-loop-start.sh" \
  "$project_root/scripts/clasp-codex-loop-status.sh" \
  "$project_root/scripts/clasp-codex-loop-stop.sh" \
  "$project_root/scripts/clasp-swarm-common.sh" \
  "$project_root/scripts/clasp-verifier.sh" \
  "$project_dir/scripts/"
cp \
  "$project_root/agents/schemas/builder-report.schema.json" \
  "$project_root/agents/schemas/verifier-report.schema.json" \
  "$project_dir/agents/schemas/"

chmod +x \
  "$project_dir/scripts/clasp-builder.sh" \
  "$project_dir/scripts/clasp-codex-loop.sh" \
  "$project_dir/scripts/clasp-codex-loop-start.sh" \
  "$project_dir/scripts/clasp-codex-loop-status.sh" \
  "$project_dir/scripts/clasp-codex-loop-stop.sh" \
  "$project_dir/scripts/clasp-verifier.sh"

cat > "$project_dir/task.md" <<'EOF'
# LOOP-001

## Goal

Make the builder react to verifier feedback.
EOF

cat > "$workspace_dir/app.txt" <<'EOF'
initial
EOF

cat > "$project_dir/tools/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output_file=""
workspace=""
prompt=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      output_file="$2"
      shift 2
      ;;
    --cd)
      workspace="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

prompt="$(cat)"

if [[ "$prompt" == *"You are the builder subagent"* ]]; then
  if [[ "$prompt" == *"Verifier feedback from the previous attempt:"* ]]; then
    printf '%s\n' 'fixed-after-feedback' > "$workspace/app.txt"
  else
    printf '%s\n' 'first-attempt' > "$workspace/app.txt"
  fi
  cat > "$output_file" <<'JSON'
{
  "summary": "stub builder report",
  "files_touched": ["app.txt"],
  "tests_run": [],
  "residual_risks": []
}
JSON
  exit 0
fi

if [[ "$prompt" == *"You are the verifier subagent"* ]]; then
  if [[ "$(< "$workspace/app.txt")" == "fixed-after-feedback" ]]; then
    cat > "$output_file" <<'JSON'
{
  "verdict": "pass",
  "summary": "verifier accepted the workspace",
  "findings": [],
  "tests_run": ["fake verifier check"],
  "follow_up": []
}
JSON
  else
    cat > "$output_file" <<'JSON'
{
  "verdict": "fail",
  "summary": "workspace still needs the feedback-driven fix",
  "findings": ["app.txt still has the first-attempt content"],
  "tests_run": ["fake verifier check"],
  "follow_up": ["Use the verifier feedback to update app.txt"]
}
JSON
  fi
  exit 0
fi

echo "unexpected prompt" >&2
exit 1
EOF
chmod +x "$project_dir/tools/codex"

(
  cd "$project_dir"
  PATH="$project_dir/tools:$PATH" \
    CLASP_SWARM_CODEX_SANDBOX=workspace-write \
    CLASP_CODEX_LOOP_MAX_ATTEMPTS=3 \
    bash scripts/clasp-codex-loop.sh task.md "$workspace_dir" "$runtime_dir" >/dev/null
)

[[ "$(< "$workspace_dir/app.txt")" == "fixed-after-feedback" ]]
[[ -d "$runtime_dir/runs" ]]
[[ "$(find "$runtime_dir/runs" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" == "2" ]]

latest_verifier_report="$(
  find "$runtime_dir/runs" -name verifier-report.json | sort | tail -n 1
)"
[[ "$(node -e 'const fs=require("fs"); const data=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(data.verdict);' "$latest_verifier_report")" == "pass" ]]

cat > "$project_dir/tools/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "timeout should not be called when loop timeouts are disabled" >&2
exit 97
EOF
chmod +x "$project_dir/tools/timeout"

workspace_dir_2="$project_dir/workspace-no-timeout"
runtime_dir_2="$project_dir/runtime-no-timeout"
mkdir -p "$workspace_dir_2"
cat > "$workspace_dir_2/app.txt" <<'EOF'
initial
EOF

(
  cd "$project_dir"
  PATH="$project_dir/tools:$PATH" \
    CLASP_SWARM_CODEX_SANDBOX=workspace-write \
    CLASP_CODEX_LOOP_MAX_ATTEMPTS=3 \
    bash scripts/clasp-codex-loop.sh task.md "$workspace_dir_2" "$runtime_dir_2" >/dev/null
)

[[ "$(< "$workspace_dir_2/app.txt")" == "fixed-after-feedback" ]]

cat > "$project_dir/tools/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output_file=""
workspace=""
prompt=""
state_root="$(cd "$(dirname "$0")/.." && pwd)/state"
mkdir -p "$state_root"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      output_file="$2"
      shift 2
      ;;
    --cd)
      workspace="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

prompt="$(cat)"

if [[ "$prompt" == *"You are the builder subagent"* ]]; then
  if [[ "$prompt" == *"Verifier feedback from the previous attempt:"* ]]; then
    printf '%s\n' 'fixed-after-feedback' > "$workspace/app.txt"
    cat > "$output_file" <<'JSON'
{
  "summary": "builder recovered after feedback",
  "files_touched": ["app.txt"],
  "tests_run": [],
  "residual_risks": []
}
JSON
    exit 0
  fi

  if [[ ! -f "$state_root/builder-crashed-once" ]]; then
    touch "$state_root/builder-crashed-once"
    exit 86
  fi

  printf '%s\n' 'first-attempt' > "$workspace/app.txt"
  cat > "$output_file" <<'JSON'
{
  "summary": "builder normal attempt",
  "files_touched": ["app.txt"],
  "tests_run": [],
  "residual_risks": []
}
JSON
  exit 0
fi

if [[ "$prompt" == *"You are the verifier subagent"* ]]; then
  if [[ "$(< "$workspace/app.txt")" == "fixed-after-feedback" ]]; then
    cat > "$output_file" <<'JSON'
{
  "verdict": "pass",
  "summary": "verifier accepted the workspace after builder crash recovery",
  "findings": [],
  "tests_run": ["fake verifier check"],
  "follow_up": []
}
JSON
  else
    cat > "$output_file" <<'JSON'
{
  "verdict": "fail",
  "summary": "builder crash left the workspace unchanged",
  "findings": ["app.txt was not repaired after the crashed builder attempt"],
  "tests_run": ["fake verifier check"],
  "follow_up": ["Use the verifier feedback to repair app.txt on the next attempt"]
}
JSON
  fi
  exit 0
fi

echo "unexpected prompt" >&2
exit 1
EOF
chmod +x "$project_dir/tools/codex"

workspace_dir_3="$project_dir/workspace-builder-crash"
runtime_dir_3="$project_dir/runtime-builder-crash"
rm -rf "$project_dir/state"
mkdir -p "$workspace_dir_3"
cat > "$workspace_dir_3/app.txt" <<'EOF'
initial
EOF

(
  cd "$project_dir"
  PATH="$project_dir/tools:$PATH" \
    CLASP_SWARM_CODEX_SANDBOX=workspace-write \
    CLASP_CODEX_LOOP_MAX_ATTEMPTS=3 \
    bash scripts/clasp-codex-loop.sh task.md "$workspace_dir_3" "$runtime_dir_3" >/dev/null
)

[[ "$(< "$workspace_dir_3/app.txt")" == "fixed-after-feedback" ]]
first_builder_crash_report="$(
  find "$runtime_dir_3/runs" -path '*attempt1/builder-report.json' | sort | tail -n 1
)"
[[ "$(node -e 'const fs=require("fs"); const data=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(data.summary);' "$first_builder_crash_report")" == "Loop builder step failed during builder." ]]

cat > "$project_dir/tools/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output_file=""
workspace=""
prompt=""
state_root="$(cd "$(dirname "$0")/.." && pwd)/state"
mkdir -p "$state_root"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      output_file="$2"
      shift 2
      ;;
    --cd)
      workspace="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

prompt="$(cat)"

if [[ "$prompt" == *"You are the builder subagent"* ]]; then
  if [[ "$prompt" == *"Verifier feedback from the previous attempt:"* ]]; then
    printf '%s\n' 'fixed-after-feedback' > "$workspace/app.txt"
  else
    printf '%s\n' 'first-attempt' > "$workspace/app.txt"
  fi
  cat > "$output_file" <<'JSON'
{
  "summary": "builder completed",
  "files_touched": ["app.txt"],
  "tests_run": [],
  "residual_risks": []
}
JSON
  exit 0
fi

if [[ "$prompt" == *"You are the verifier subagent"* ]]; then
  if [[ ! -f "$state_root/verifier-crashed-once" ]]; then
    touch "$state_root/verifier-crashed-once"
    exit 91
  fi

  if [[ "$(< "$workspace/app.txt")" == "fixed-after-feedback" ]]; then
    cat > "$output_file" <<'JSON'
{
  "verdict": "pass",
  "summary": "verifier accepted the workspace after verifier crash recovery",
  "findings": [],
  "tests_run": ["fake verifier check"],
  "follow_up": []
}
JSON
  else
    cat > "$output_file" <<'JSON'
{
  "verdict": "fail",
  "summary": "workspace still needs the feedback-driven fix",
  "findings": ["app.txt still has the first-attempt content"],
  "tests_run": ["fake verifier check"],
  "follow_up": ["Use the verifier feedback to update app.txt"]
}
JSON
  fi
  exit 0
fi

echo "unexpected prompt" >&2
exit 1
EOF
chmod +x "$project_dir/tools/codex"

workspace_dir_4="$project_dir/workspace-verifier-crash"
runtime_dir_4="$project_dir/runtime-verifier-crash"
rm -rf "$project_dir/state"
mkdir -p "$workspace_dir_4"
cat > "$workspace_dir_4/app.txt" <<'EOF'
initial
EOF

(
  cd "$project_dir"
  PATH="$project_dir/tools:$PATH" \
    CLASP_SWARM_CODEX_SANDBOX=workspace-write \
    CLASP_CODEX_LOOP_MAX_ATTEMPTS=3 \
    bash scripts/clasp-codex-loop.sh task.md "$workspace_dir_4" "$runtime_dir_4" >/dev/null
)

[[ "$(< "$workspace_dir_4/app.txt")" == "fixed-after-feedback" ]]
first_verifier_crash_report="$(
  find "$runtime_dir_4/runs" -path '*attempt1/verifier-report.json' | sort | tail -n 1
)"
[[ "$(node -e 'const fs=require("fs"); const data=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(data.verdict);' "$first_verifier_crash_report")" == "fail" ]]
[[ "$(node -e 'const fs=require("fs"); const data=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(data.summary);' "$first_verifier_crash_report")" == "Fail: loop verifier failed before verifier could complete cleanly." ]]

cat > "$project_dir/scripts/clasp-codex-loop.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

task_file="$1"
workspace="$2"
runtime_dir="$3"
mkdir -p "$runtime_dir"
printf 'loop-start:%s\n' "$(basename "$task_file")" >> "$runtime_dir/lifecycle.log"
trap 'printf "%s\n" stop >> "$runtime_dir/lifecycle.log"; exit 0' TERM INT
while :; do
  sleep 1
done
EOF
chmod +x "$project_dir/scripts/clasp-codex-loop.sh"

runtime_dir_5="$project_dir/runtime-detached-start"
start_output="$(
  cd "$project_dir" && \
  bash scripts/clasp-codex-loop-start.sh task.md "$workspace_dir" "$runtime_dir_5"
)"
printf '%s\n' "$start_output" | grep -F 'started codex loop pid=' >/dev/null
status_output="$(
  cd "$project_dir" && \
  bash scripts/clasp-codex-loop-status.sh task.md "$workspace_dir" "$runtime_dir_5"
)"
printf '%s\n' "$status_output" | grep -F 'status: running' >/dev/null
printf '%s\n' "$status_output" | grep -F "runtime: $runtime_dir_5" >/dev/null
pid_5="$(cat "$runtime_dir_5/loop.pid")"
kill -0 "$pid_5" >/dev/null 2>&1
grep -F 'loop-start:task.md' "$runtime_dir_5/lifecycle.log" >/dev/null
stop_output="$(
  cd "$project_dir" && \
  bash scripts/clasp-codex-loop-stop.sh task.md "$workspace_dir" "$runtime_dir_5"
)"
printf '%s\n' "$stop_output" | grep -F "stopped codex loop pid=$pid_5" >/dev/null
sleep 1
if kill -0 "$pid_5" >/dev/null 2>&1; then
  echo "detached codex loop should have stopped" >&2
  exit 1
fi
