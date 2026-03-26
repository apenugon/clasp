#!/usr/bin/env bash
set -euo pipefail

suite_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
node "$suite_root/run-live-codex-suite.mjs"
