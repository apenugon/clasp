#!/usr/bin/env bash

# Normalize stale inherited TMPDIR values, especially deleted nix-shell
# directories under /tmp. Source this before mktemp or wrapper re-entry.
clasp_tmpdir_candidate="${TMPDIR:-/tmp}"

if [[ -d "$clasp_tmpdir_candidate" && -w "$clasp_tmpdir_candidate" && -x "$clasp_tmpdir_candidate" ]]; then
  export TMPDIR="$clasp_tmpdir_candidate"
elif [[ ! -e "$clasp_tmpdir_candidate" ]]; then
  clasp_tmpdir_parent="$(dirname "$clasp_tmpdir_candidate")"
  clasp_tmpdir_can_create=0
  case "$clasp_tmpdir_candidate" in
    /tmp/*|/var/tmp/*)
      clasp_tmpdir_can_create=1
      ;;
  esac

  if [[ "$clasp_tmpdir_can_create" == "1" && -d "$clasp_tmpdir_parent" && -w "$clasp_tmpdir_parent" && -x "$clasp_tmpdir_parent" ]]; then
    mkdir -p "$clasp_tmpdir_candidate" 2>/dev/null || true
  fi

  if [[ -d "$clasp_tmpdir_candidate" && -w "$clasp_tmpdir_candidate" && -x "$clasp_tmpdir_candidate" ]]; then
    export TMPDIR="$clasp_tmpdir_candidate"
  elif [[ -d /tmp && -w /tmp && -x /tmp ]]; then
    export TMPDIR="/tmp"
  else
    printf 'normalize-tmpdir: unable to use TMPDIR=%s or /tmp\n' "$clasp_tmpdir_candidate" >&2
    exit 1
  fi
elif [[ -d /tmp && -w /tmp && -x /tmp ]]; then
  export TMPDIR="/tmp"
else
  printf 'normalize-tmpdir: unable to use TMPDIR=%s or /tmp\n' "$clasp_tmpdir_candidate" >&2
  exit 1
fi

unset clasp_tmpdir_candidate
unset clasp_tmpdir_parent
unset clasp_tmpdir_can_create
