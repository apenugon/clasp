#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n \
  "$project_root/scripts/clasp-swarm-common.sh" \
  "$project_root/scripts/clasp-swarm-lane.sh" \
  "$project_root/scripts/clasp-swarm-start.sh" \
  "$project_root/scripts/clasp-swarm-status.sh" \
  "$project_root/scripts/clasp-swarm-stop.sh"

python3 - "$project_root" <<'PY'
import json
import pathlib
import sys

project_root = pathlib.Path(sys.argv[1])
schema_path = project_root / "agents/swarm/task.schema.json"
template_path = project_root / "agents/swarm/task-template.md"
readme_path = project_root / "agents/swarm/README.md"
agents_readme_path = project_root / "agents/README.md"
plan_path = project_root / "docs/clasp-project-plan.md"

schema = json.loads(schema_path.read_text())
deps = schema["properties"]["dependencies"]
assert deps["type"] == "array"
assert deps["items"]["pattern"] == "^[A-Z]{2,3}-[0-9]{3}$"

template = template_path.read_text()
assert '"dependencies": []' in template

readme = readme_path.read_text()
assert "./task-template.md" in readme
assert "./task.schema.json" in readme
assert str(project_root) not in readme

agents_readme = agents_readme_path.read_text()
assert "The canonical backlog now lives under `agents/swarm/`." in agents_readme
assert "`agents/swarm/task-template.md`" in agents_readme
assert "`agents/swarm/task.schema.json`" in agents_readme
assert "`agents/tasks/` remains only as the legacy coarse backlog" in agents_readme

plan = plan_path.read_text()
assert "agents/swarm/task-template.md" in plan
assert "agents/swarm/task.schema.json" in plan
assert "dependencies` must be a JSON array of task IDs, with `[]` meaning no dependencies" in plan
PY

mapfile -t lanes < <(bash "$project_root/scripts/clasp-swarm-start.sh" --list-lanes wave1)

if [[ "${#lanes[@]}" -lt 1 ]]; then
  echo "expected at least one wave1 lane" >&2
  exit 1
fi

for lane_dir in "${lanes[@]}"; do
  bash "$project_root/scripts/clasp-swarm-lane.sh" --list-tasks "$lane_dir" >/dev/null
done

bash "$project_root/scripts/clasp-swarm-status.sh" wave1 >/dev/null

mapfile -t default_lanes < <(bash "$project_root/scripts/clasp-swarm-start.sh" --list-lanes)

if [[ "${#default_lanes[@]}" -lt 1 ]]; then
  echo "expected at least one default-wave lane" >&2
  exit 1
fi

for lane_dir in "${default_lanes[@]}"; do
  bash "$project_root/scripts/clasp-swarm-lane.sh" --list-tasks "$lane_dir" >/dev/null
done

bash "$project_root/scripts/clasp-swarm-status.sh" >/dev/null

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/clasp-swarm-control.XXXXXX")"

cleanup() {
  rm -rf "$tmpdir"
}

trap cleanup EXIT

assert_file_exists() {
  local path="$1"

  if [[ ! -e "$path" ]]; then
    echo "expected file to exist: $path" >&2
    exit 1
  fi
}

assert_file_not_exists() {
  local path="$1"

  if [[ -e "$path" ]]; then
    echo "expected file to be absent: $path" >&2
    exit 1
  fi
}

assert_contains() {
  local path="$1"
  local pattern="$2"

  if ! grep -Fq -- "$pattern" "$path"; then
    echo "expected '$pattern' in $path" >&2
    exit 1
  fi
}

assert_not_contains() {
  local path="$1"
  local pattern="$2"

  if grep -Fq -- "$pattern" "$path"; then
    echo "did not expect '$pattern' in $path" >&2
    exit 1
  fi
}

assert_lines_equal() {
  local path="$1"
  shift
  local expected=("$@")
  local actual=()

  mapfile -t actual < "$path"

  if [[ "${#actual[@]}" -ne "${#expected[@]}" ]]; then
    echo "unexpected line count in $path: got ${#actual[@]}, want ${#expected[@]}" >&2
    printf 'actual lines:\n' >&2
    printf '  %s\n' "${actual[@]}" >&2
    exit 1
  fi

  local index
  for index in "${!expected[@]}"; do
    if [[ "${actual[$index]}" != "${expected[$index]}" ]]; then
      echo "unexpected line $((index + 1)) in $path: got '${actual[$index]}', want '${expected[$index]}'" >&2
      exit 1
    fi
  done
}

assert_file_size_at_least() {
  local path="$1"
  local minimum_size="$2"
  local actual_size

  actual_size="$(wc -c < "$path" | tr -d ' ')"

  if (( actual_size < minimum_size )); then
    echo "expected $path to be at least $minimum_size bytes, got $actual_size" >&2
    exit 1
  fi
}

create_fake_codex() {
  local fixture_root="$1"

  mkdir -p "$fixture_root/fake-bin" "$fixture_root/.test-state"

  cat <<'EOF' > "$fixture_root/fake-bin/codex"
#!/usr/bin/env bash
set -euo pipefail

state_dir="${CLASP_FAKE_CODEX_STATE_DIR:?}"
call_id="${CLASP_FAKE_CODEX_CALL_ID:?}"
args_file="$state_dir/$call_id.args"
prompt_file="$state_dir/$call_id.prompt"

printf '%s\n' "$@" > "$args_file"
cat > "$prompt_file"

output_file=""
previous=""
for arg in "$@"; do
  if [[ "$previous" == "-o" ]]; then
    output_file="$arg"
    break
  fi
  previous="$arg"
done

if [[ -z "$output_file" ]]; then
  echo "fake codex expected -o <output-file>" >&2
  exit 1
fi

case "$call_id" in
  builder)
    printf '{"summary":"builder ok","files_touched":[],"tests_run":[],"residual_risks":[]}\n' > "$output_file"
    ;;
  verifier)
    printf '{"verdict":"pass","summary":"verifier ok","findings":[],"tests_run":[],"follow_up":[]}\n' > "$output_file"
    ;;
  *)
    echo "unexpected fake codex call id: $call_id" >&2
    exit 1
    ;;
esac
EOF

  chmod +x "$fixture_root/fake-bin/codex"
}

run_prompt_script_with_fake_codex() {
  local fixture_root="$1"
  local call_id="$2"
  shift 2

  (
    cd "$project_root"
    env \
      PATH="$fixture_root/fake-bin:$PATH" \
      CLASP_FAKE_CODEX_STATE_DIR="$fixture_root/.test-state" \
      CLASP_FAKE_CODEX_CALL_ID="$call_id" \
      "$@"
  )
}

test_builder_prompt_is_literal_safe_and_streamed_via_stdin() {
  local fixture_root="$tmpdir/builder-prompt"
  local workspace="$fixture_root/workspace"
  local task_file="$fixture_root/task.md"
  local feedback_file="$fixture_root/feedback.json"
  local report_json="$fixture_root/report.json"
  local log_jsonl="$fixture_root/log.jsonl"
  local prompt_file="$fixture_root/.test-state/builder.prompt"
  local args_file="$fixture_root/.test-state/builder.args"
  local interpolation_marker="$fixture_root/marker-builder"
  local huge_payload

  mkdir -p "$workspace"
  create_fake_codex "$fixture_root"
  huge_payload="$(printf 'builder payload %.0s' $(seq 1 14000))"

  cat <<EOF > "$task_file"
# SW-003 Builder Prompt Test

Literal shell text must survive:
\$(touch "$interpolation_marker")
\`touch "$interpolation_marker"\`
$huge_payload
EOF

  cat <<EOF > "$feedback_file"
{"summary":"prior verifier said \$(touch \"$interpolation_marker\")","findings":["first finding with \`touch \"$interpolation_marker\"\`","$huge_payload"],"follow_up":["keep the prompt file path literal"]}
EOF

  run_prompt_script_with_fake_codex \
    "$fixture_root" \
    builder \
    bash "$project_root/scripts/clasp-builder.sh" \
    "$task_file" \
    "$workspace" \
    "$report_json" \
    "$log_jsonl" \
    "$feedback_file"

  assert_file_exists "$report_json"
  assert_file_exists "$log_jsonl"
  assert_file_exists "$prompt_file"
  assert_file_exists "$args_file"
  assert_file_not_exists "$interpolation_marker"
  assert_contains "$prompt_file" '$(touch "'
  assert_contains "$prompt_file" '`touch "'
  assert_contains "$prompt_file" "Verifier feedback from the previous attempt:"
  assert_contains "$prompt_file" "Task:"
  assert_contains "$args_file" "exec"
  assert_contains "$args_file" "-"
  assert_contains "$args_file" "--output-schema"
  assert_not_contains "$args_file" "builder payload builder payload builder payload"
  assert_file_size_at_least "$prompt_file" 200000
}

test_verifier_prompt_is_literal_safe_and_streamed_via_stdin() {
  local fixture_root="$tmpdir/verifier-prompt"
  local workspace="$fixture_root/workspace"
  local baseline_workspace="$fixture_root/baseline \$(touch marker-verifier)"
  local task_file="$fixture_root/task.md"
  local report_json="$fixture_root/report.json"
  local log_jsonl="$fixture_root/log.jsonl"
  local prompt_file="$fixture_root/.test-state/verifier.prompt"
  local args_file="$fixture_root/.test-state/verifier.args"
  local interpolation_marker="$fixture_root/marker-verifier"
  local huge_payload

  mkdir -p "$workspace" "$baseline_workspace"
  create_fake_codex "$fixture_root"
  huge_payload="$(printf 'verifier payload %.0s' $(seq 1 14000))"

  cat <<EOF > "$task_file"
# SW-003 Verifier Prompt Test

Literal shell text must survive:
\$(touch "$interpolation_marker")
\`touch "$interpolation_marker"\`
$huge_payload
EOF

  run_prompt_script_with_fake_codex \
    "$fixture_root" \
    verifier \
    bash "$project_root/scripts/clasp-verifier.sh" \
    "$task_file" \
    "$workspace" \
    "$baseline_workspace" \
    "$report_json" \
    "$log_jsonl"

  assert_file_exists "$report_json"
  assert_file_exists "$log_jsonl"
  assert_file_exists "$prompt_file"
  assert_file_exists "$args_file"
  assert_file_not_exists "$interpolation_marker"
  assert_contains "$prompt_file" "Baseline workspace: $baseline_workspace"
  assert_contains "$prompt_file" '$(touch "'
  assert_contains "$prompt_file" '`touch "'
  assert_contains "$prompt_file" "Task:"
  assert_contains "$args_file" "exec"
  assert_contains "$args_file" "-"
  assert_contains "$args_file" "--output-schema"
  assert_not_contains "$args_file" "verifier payload verifier payload verifier payload"
  assert_file_size_at_least "$prompt_file" 220000
}

create_autopilot_fixture() {
  local fixture_root="$1"

  mkdir -p "$fixture_root/scripts" "$fixture_root/agents/tasks" "$fixture_root/.test-state"

  cp \
    "$project_root/scripts/clasp-autopilot.sh" \
    "$project_root/scripts/clasp-autopilot-start.sh" \
    "$project_root/scripts/clasp-autopilot-status.sh" \
    "$project_root/scripts/clasp-autopilot-stop.sh" \
    "$fixture_root/scripts/"

  cat <<'EOF' > "$fixture_root/AGENTS.md"
# Fixture
EOF

  cat <<'EOF' > "$fixture_root/scripts/clasp-builder.sh"
#!/usr/bin/env bash
set -euo pipefail

task_file="$1"
workspace="$2"
report_json="$3"
log_jsonl="$4"
feedback_file="${5:-}"
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state_root="$project_root/.test-state"
task_id="$(basename "$task_file" .md)"

mkdir -p "$state_root"
printf '%s\n' "$task_id" >> "$state_root/build-order.txt"

if [[ "$task_id" == "0001-alpha--workaround" ]]; then
  if [[ -f "$state_root/require-generated-workaround" ]]; then
    grep -Fq "# 0001-alpha--workaround" "$task_file"
    grep -Fq "Verifier Summary" "$task_file"
    grep -Fq "Alpha verification failed." "$task_file"
    grep -Fq "Recent verifier log lines:" "$task_file"
  fi

  if [[ -f "$state_root/require-preseeded-workaround" ]]; then
    grep -Fq "Preseeded workaround task." "$task_file"
  fi
fi

if [[ -n "$feedback_file" ]]; then
  printf '%s\n' "$feedback_file" >> "$state_root/feedback-files.txt"
fi

printf '{"summary":"builder ok","files_touched":[],"tests_run":[],"residual_risks":[]}\n' > "$report_json"
printf '{"event":"builder","task":"%s","workspace":"%s"}\n' "$task_id" "$workspace" > "$log_jsonl"
EOF

  cat <<'EOF' > "$fixture_root/scripts/clasp-verifier.sh"
#!/usr/bin/env bash
set -euo pipefail

task_file="$1"
workspace="$2"
baseline_workspace="$3"
report_json="$4"
log_jsonl="$5"
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state_root="$project_root/.test-state"
task_id="$(basename "$task_file" .md)"

mkdir -p "$state_root"
printf '%s\n' "$task_id" >> "$state_root/verify-order.txt"
printf '{"event":"verifier","task":"%s","workspace":"%s","baseline":"%s"}\n' \
  "$task_id" \
  "$workspace" \
  "$baseline_workspace" > "$log_jsonl"

case "$task_id" in
  0001-alpha)
    if [[ -f "$state_root/workaround-complete" ]]; then
      printf '{"verdict":"pass","summary":"Alpha verified.","findings":[],"tests_run":["retry alpha"],"follow_up":[]}\n' > "$report_json"
    else
      printf '{"verdict":"fail","summary":"Alpha verification failed.","findings":["Need a smaller follow-up.","Recent verifier log lines:\\nalpha root cause"],"tests_run":["attempt alpha"],"follow_up":["Split the change."]}\n' > "$report_json"
    fi
    ;;
  0001-alpha--workaround)
    : > "$state_root/workaround-complete"
    printf '{"verdict":"pass","summary":"Workaround verified.","findings":[],"tests_run":["workaround coverage"],"follow_up":[]}\n' > "$report_json"
    ;;
  0002-beta)
    printf '{"verdict":"pass","summary":"Beta verified.","findings":[],"tests_run":["beta coverage"],"follow_up":[]}\n' > "$report_json"
    ;;
  0003-gamma)
    printf '{"verdict":"pass","summary":"Gamma verified.","findings":[],"tests_run":["gamma coverage"],"follow_up":[]}\n' > "$report_json"
    ;;
  *)
    echo "unexpected task id: $task_id" >&2
    exit 1
    ;;
esac
EOF

  chmod +x "$fixture_root"/scripts/clasp-*.sh
}

run_autopilot_fixture() {
  local fixture_root="$1"
  shift

  (
    cd "$fixture_root"
    env \
      CLASP_AUTOPILOT_RETRY_LIMIT=1 \
      CLASP_AUTOPILOT_ALLOW_DIRTY_ROOT=1 \
      "$@" \
      bash scripts/clasp-autopilot.sh
  ) >"$fixture_root/.test-state/autopilot-output.log" 2>&1
}

test_autopilot_generates_workaround_and_retries_base_task() {
  local fixture_root="$tmpdir/autopilot-generated-workaround"
  local generated_task="$fixture_root/.clasp-agents/generated-tasks/0001-alpha--workaround.md"

  create_autopilot_fixture "$fixture_root"
  : > "$fixture_root/.test-state/require-generated-workaround"

  cat <<'EOF' > "$fixture_root/agents/tasks/0001-alpha.md"
# Alpha
EOF

  cat <<'EOF' > "$fixture_root/agents/tasks/0002-beta.md"
# Beta
EOF

  run_autopilot_fixture "$fixture_root"

  assert_file_exists "$fixture_root/.clasp-agents/completed/0001-alpha"
  assert_file_exists "$fixture_root/.clasp-agents/completed/0002-beta"
  assert_file_not_exists "$fixture_root/.clasp-agents/blocked/0001-alpha.json"
  assert_file_not_exists "$generated_task"
  assert_file_not_exists "$fixture_root/.clasp-agents/current-task.txt"
  assert_file_not_exists "$fixture_root/.clasp-agents/autopilot.pid"
  assert_lines_equal \
    "$fixture_root/.test-state/build-order.txt" \
    "0001-alpha" \
    "0001-alpha--workaround" \
    "0001-alpha" \
    "0002-beta"
}

test_autopilot_resumes_existing_workaround_after_restart() {
  local fixture_root="$tmpdir/autopilot-resume-workaround"

  create_autopilot_fixture "$fixture_root"
  : > "$fixture_root/.test-state/require-preseeded-workaround"

  cat <<'EOF' > "$fixture_root/agents/tasks/0001-alpha.md"
# Alpha
EOF

  cat <<'EOF' > "$fixture_root/agents/tasks/0002-beta.md"
# Beta
EOF

  mkdir -p "$fixture_root/.clasp-agents/blocked" "$fixture_root/.clasp-agents/generated-tasks"
  cat <<'EOF' > "$fixture_root/.clasp-agents/blocked/0001-alpha.json"
{"verdict":"fail","summary":"Seeded blocked report","findings":["Existing failure"],"tests_run":[],"follow_up":[]}
EOF

  cat <<'EOF' > "$fixture_root/.clasp-agents/generated-tasks/0001-alpha--workaround.md"
# 0001-alpha--workaround

Preseeded workaround task.
EOF

  run_autopilot_fixture "$fixture_root"

  assert_file_exists "$fixture_root/.clasp-agents/completed/0001-alpha"
  assert_file_exists "$fixture_root/.clasp-agents/completed/0002-beta"
  assert_file_not_exists "$fixture_root/.clasp-agents/blocked/0001-alpha.json"
  assert_file_not_exists "$fixture_root/.clasp-agents/generated-tasks/0001-alpha--workaround.md"
  assert_lines_equal \
    "$fixture_root/.test-state/build-order.txt" \
    "0001-alpha--workaround" \
    "0001-alpha" \
    "0002-beta"
}

test_autopilot_skips_blocked_workaround_and_runs_later_tasks() {
  local fixture_root="$tmpdir/autopilot-blocked-workaround"

  create_autopilot_fixture "$fixture_root"

  cat <<'EOF' > "$fixture_root/agents/tasks/0002-beta.md"
# Beta
EOF

  cat <<'EOF' > "$fixture_root/agents/tasks/0003-gamma.md"
# Gamma
EOF

  mkdir -p "$fixture_root/.clasp-agents/blocked" "$fixture_root/.clasp-agents/generated-tasks"
  cat <<'EOF' > "$fixture_root/.clasp-agents/blocked/0001-alpha--workaround.json"
{"verdict":"fail","summary":"Blocked workaround","findings":["Still blocked"],"tests_run":[],"follow_up":[]}
EOF

  cat <<'EOF' > "$fixture_root/.clasp-agents/generated-tasks/0001-alpha--workaround.md"
# 0001-alpha--workaround

Blocked workaround task.
EOF

  run_autopilot_fixture "$fixture_root"

  assert_file_exists "$fixture_root/.clasp-agents/completed/0002-beta"
  assert_file_exists "$fixture_root/.clasp-agents/completed/0003-gamma"
  assert_file_exists "$fixture_root/.clasp-agents/blocked/0001-alpha--workaround.json"
  assert_lines_equal \
    "$fixture_root/.test-state/build-order.txt" \
    "0002-beta" \
    "0003-gamma"
  assert_contains "$fixture_root/.test-state/autopilot-output.log" "workaround task 0001-alpha--workaround is blocked; leaving it blocked and continuing"
}

test_autopilot_generates_workaround_and_retries_base_task
test_autopilot_resumes_existing_workaround_after_restart
test_autopilot_skips_blocked_workaround_and_runs_later_tasks
test_builder_prompt_is_literal_safe_and_streamed_via_stdin
test_verifier_prompt_is_literal_safe_and_streamed_via_stdin
