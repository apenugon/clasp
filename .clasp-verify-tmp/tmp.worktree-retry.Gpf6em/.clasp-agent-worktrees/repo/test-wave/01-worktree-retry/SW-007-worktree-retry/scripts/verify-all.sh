#!/usr/bin/env bash
set -euo pipefail
[[ "$(< feature.txt)" == "recovered-builder-change" ]]
