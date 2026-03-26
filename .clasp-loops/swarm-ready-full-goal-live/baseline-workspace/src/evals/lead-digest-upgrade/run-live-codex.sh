#!/usr/bin/env bash
set -euo pipefail

eval_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
node "$eval_root/run-live-codex.mjs"
