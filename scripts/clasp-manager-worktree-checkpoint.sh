#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state_root="${1:-${CLASP_MANAGER_STATE_ROOT:-swarm-native-goal-manager-state}}"
checkpoint_path="${CLASP_MANAGER_WORKTREE_CHECKPOINT_PATH:-$state_root/worktree-checkpoint.json}"

usage() {
  cat <<'EOF' >&2
usage: scripts/clasp-manager-worktree-checkpoint.sh [state-root]

Writes a manager worktree checkpoint manifest for the current Git status shape.
GoalManagerResourceHealth accepts this manifest only when its project root and
git status --porcelain --untracked-files=normal text match the current state.
EOF
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
esac

project_root_abs="$(cd "$project_root" && pwd -P)"
status_text="$(git -C "$project_root_abs" status --porcelain --untracked-files=normal)"

mkdir -p "$(dirname "$checkpoint_path")"

STATUS_TEXT="$status_text" node - "$checkpoint_path" "$project_root_abs" <<'NODE'
const fs = require("node:fs");

const [checkpointPath, projectRoot] = process.argv.slice(2);
const statusText = process.env.STATUS_TEXT || "";

fs.writeFileSync(
  checkpointPath,
  `${JSON.stringify(
    {
      schemaVersion: 1,
      kind: "clasp-manager-worktree-checkpoint",
      projectRoot,
      statusText,
    },
    null,
    2,
  )}\n`,
);

process.stdout.write(`${checkpointPath}\n`);
NODE
