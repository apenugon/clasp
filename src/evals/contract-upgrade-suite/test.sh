#!/usr/bin/env bash
set -euo pipefail

suite_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
start_root="$suite_root/common/start"

for task_dir in "$suite_root"/tasks/*; do
  task_id="$(basename "$task_dir")"

  if bash "$suite_root/validate.sh" "$task_id" "$start_root" >/tmp/clasp-contract-suite-"$task_id"-start.out 2>/tmp/clasp-contract-suite-"$task_id"-start.err; then
    echo "expected common start fixture to fail target validation for $task_id" >&2
    exit 1
  fi

  bash "$suite_root/validate.sh" "$task_id" "$task_dir/solution"
done
