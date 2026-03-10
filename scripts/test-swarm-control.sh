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
