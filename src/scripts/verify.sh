#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
compiler_root="$project_root/src"
embedded_native_path="$compiler_root/embedded.native.image.json"
embedded_compiler_native_path="$compiler_root/embedded.compiler.native.image.json"
verify_root="$compiler_root/native-verify"
verify_cache_root="$compiler_root/native-verify-cache"
reset_verify_cache="${CLASP_NATIVE_VERIFY_RESET_CACHE:-0}"
verify_mode="${CLASP_NATIVE_VERIFY_MODE:-fast}"
verify_lock_file="${CLASP_NATIVE_VERIFY_LOCK_FILE:-$compiler_root/.native-verify.lock}"
verify_lock_dir="${verify_lock_file}.d"
verify_lock_owner=0
native_image_plan_field_separator=$'\n-- CLASP_NATIVE_IMAGE_PLAN_FIELD --\n'
native_image_decl_plan_field_separator=$'\n-- CLASP_NATIVE_IMAGE_DECL_PLAN_FIELD --\n'
native_image_decl_module_separator=$'\n-- CLASP_NATIVE_IMAGE_DECL_MODULE --\n'
native_image_decl_module_field_separator=$'\n-- CLASP_NATIVE_IMAGE_DECL_MODULE_FIELD --\n'

cleanup() {
  rm -rf "$verify_root"
  if [[ "$reset_verify_cache" == "1" ]]; then
    rm -rf "$verify_cache_root"
  fi
  release_verify_lock
}

trap cleanup EXIT

release_verify_lock() {
  if [[ "$verify_lock_owner" != "1" ]]; then
    return 0
  fi

  rm -f "$verify_lock_dir/pid"
  rmdir "$verify_lock_dir" >/dev/null 2>&1 || true
  verify_lock_owner=0
}

acquire_verify_lock() {
  local owner_pid=""

  mkdir -p "$(dirname "$verify_lock_file")"

  while ! mkdir "$verify_lock_dir" >/dev/null 2>&1; do
    owner_pid="$(cat "$verify_lock_dir/pid" 2>/dev/null || true)"
    if [[ -n "$owner_pid" ]] && ! kill -0 "$owner_pid" >/dev/null 2>&1; then
      rm -f "$verify_lock_dir/pid"
      rmdir "$verify_lock_dir" >/dev/null 2>&1 || true
      continue
    fi
    sleep 1
  done

  printf '%s\n' "$$" > "$verify_lock_dir/pid"
  verify_lock_owner=1
}

run_native_export() {
  CLASPC_BIN="$(resolve_native_claspc_bin)" \
    XDG_CACHE_HOME="$verify_cache_root/xdg" \
    bash "$project_root/src/scripts/run-native-tool.sh" "$@"
}

resolve_native_claspc_bin() {
  if [[ -n "${CLASPC_BIN:-}" ]]; then
    printf '%s\n' "$CLASPC_BIN"
  elif [[ -x "$project_root/runtime/target/debug/claspc" ]]; then
    printf '%s\n' "$project_root/runtime/target/debug/claspc"
  else
    "$project_root/scripts/resolve-claspc.sh"
  fi
}

run_native_check() {
  local input_path="$1"
  local output_path="$2"
  local claspc_bin=""

  claspc_bin="$(resolve_native_claspc_bin)"
  XDG_CACHE_HOME="$verify_cache_root/xdg" \
    "$claspc_bin" --json check "$input_path" >"$output_path"
}

module_decl_cache_path() {
  local module_name="$1"

  printf '%s\n' "$verify_cache_root/full-native-image/module-decls/${module_name//./__}.json"
}

parse_native_image_build_plan() {
  local build_plan_path="$1"
  local output_path="$2"

  node - "$build_plan_path" "$output_path" <<'JS'
const fs = require("node:fs");

const buildPlanPath = process.argv[2];
const outputPath = process.argv[3];
const fieldSeparator = "\n-- CLASP_NATIVE_IMAGE_PLAN_FIELD --\n";
const declPlanFieldSeparator = "\n-- CLASP_NATIVE_IMAGE_DECL_PLAN_FIELD --\n";
const declModuleSeparator = "\n-- CLASP_NATIVE_IMAGE_DECL_MODULE --\n";
const declModuleFieldSeparator = "\n-- CLASP_NATIVE_IMAGE_DECL_MODULE_FIELD --\n";

const text = fs.readFileSync(buildPlanPath, "utf8");
const fields = text.split(fieldSeparator);
if (fields.length !== 8) {
  throw new Error(`expected 8 native image build plan fields in ${buildPlanPath}, found ${fields.length}`);
}
const declPlanFields = fields[7].split(declPlanFieldSeparator);
if (declPlanFields.length !== 2) {
  throw new Error(`expected 2 decl plan fields in ${buildPlanPath}, found ${declPlanFields.length}`);
}
const modules = declPlanFields[1].trim() === ""
  ? []
  : declPlanFields[1].split(declModuleSeparator).filter(Boolean).map((entry) => {
      const moduleFields = entry.split(declModuleFieldSeparator);
      if (moduleFields.length !== 3) {
        throw new Error(`expected 3 module decl fields in ${buildPlanPath}, found ${moduleFields.length}`);
      }
      return {
        moduleName: moduleFields[0],
        declNamesText: moduleFields[1],
        interfaceFingerprint: moduleFields[2],
      };
    });

fs.writeFileSync(
  outputPath,
  JSON.stringify(
    {
      moduleName: fields[0],
      exportsText: fields[1],
      entrypointsText: fields[2],
      abiText: fields[3],
      runtimeText: fields[4],
      compatibilityText: fields[5],
      constructorDeclsText: fields[6],
      declPlanText: fields[7],
      declContextFingerprint: declPlanFields[0],
      modules,
    },
    null,
    2,
  ),
);
JS
}

compute_incremental_verify_modules() {
  local current_plan_json="$1"
  local previous_plan_json="$2"
  local current_decl_dir="$3"
  local cache_root="$4"
  local output_path="$5"

  node - "$project_root" "$current_plan_json" "$previous_plan_json" "$current_decl_dir" "$cache_root" "$output_path" <<'JS'
const fs = require("node:fs");
const path = require("node:path");

const projectRoot = process.argv[2];
const currentPlanPath = process.argv[3];
const previousPlanPath = process.argv[4];
const currentDeclDir = process.argv[5];
const cacheRoot = process.argv[6];
const outputPath = process.argv[7];

const currentPlan = JSON.parse(fs.readFileSync(currentPlanPath, "utf8"));
const previousPlan = fs.existsSync(previousPlanPath)
  ? JSON.parse(fs.readFileSync(previousPlanPath, "utf8"))
  : null;

const previousModules = new Map((previousPlan?.modules ?? []).map((entry) => [entry.moduleName, entry]));
const reverseImports = new Map();
for (const moduleEntry of currentPlan.modules) {
  reverseImports.set(moduleEntry.moduleName, []);
}

for (const moduleEntry of currentPlan.modules) {
  const modulePath = path.join(projectRoot, "src", ...moduleEntry.moduleName.split(".")) + ".clasp";
  let imports = [];
  if (fs.existsSync(modulePath)) {
    imports = fs
      .readFileSync(modulePath, "utf8")
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line.startsWith("import "))
      .map((line) => line.slice("import ".length).trim())
      .filter(Boolean);
  }
  for (const imported of imports) {
    if (!reverseImports.has(imported)) {
      reverseImports.set(imported, []);
    }
    reverseImports.get(imported).push(moduleEntry.moduleName);
  }
}

const dirty = new Set();
for (const moduleEntry of currentPlan.modules) {
  const currentDeclPath = path.join(currentDeclDir, `${moduleEntry.moduleName}.json`);
  const previousDeclPath = path.join(cacheRoot, "full-native-image", "module-decls", `${moduleEntry.moduleName.replace(/\./g, "__")}.json`);
  const currentDeclText = fs.existsSync(currentDeclPath) ? fs.readFileSync(currentDeclPath, "utf8") : null;
  const previousDeclText = fs.existsSync(previousDeclPath) ? fs.readFileSync(previousDeclPath, "utf8") : null;
  const previousEntry = previousModules.get(moduleEntry.moduleName);
  if (!previousEntry || currentDeclText === null || previousDeclText === null || currentDeclText !== previousDeclText) {
    dirty.add(moduleEntry.moduleName);
  }
  if (!previousEntry || previousEntry.interfaceFingerprint !== moduleEntry.interfaceFingerprint) {
    dirty.add(moduleEntry.moduleName);
    const queue = [...(reverseImports.get(moduleEntry.moduleName) ?? [])];
    while (queue.length > 0) {
      const dependent = queue.shift();
      if (dirty.has(dependent)) {
        continue;
      }
      dirty.add(dependent);
      for (const next of reverseImports.get(dependent) ?? []) {
        queue.push(next);
      }
    }
  }
}

const ordered = currentPlan.modules.map((entry) => entry.moduleName).filter((name) => dirty.has(name));
fs.writeFileSync(outputPath, ordered.join("\n"));
JS
}

refresh_full_verify_cache() {
  local current_plan_json="$1"
  local current_decl_dir="$2"

  mkdir -p "$verify_cache_root/full-native-image/module-decls"
  cp "$current_plan_json" "$verify_cache_root/full-native-image/build-plan.json"

  node - "$verify_cache_root/full-native-image/module-decls" "$current_plan_json" <<'JS'
const fs = require("node:fs");
const cacheDir = process.argv[2];
const plan = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const keep = new Set(plan.modules.map((entry) => `${entry.moduleName.replace(/\./g, "__")}.json`));
for (const entry of fs.readdirSync(cacheDir, { withFileTypes: true })) {
  if (entry.isFile() && !keep.has(entry.name)) {
    fs.rmSync(`${cacheDir}/${entry.name}`, { force: true });
  }
}
JS

  while IFS= read -r module_name || [[ -n "$module_name" ]]; do
    [[ -z "$module_name" ]] && continue
    cp "$current_decl_dir/$module_name.json" "$(module_decl_cache_path "$module_name")"
  done < <(node -e 'const fs = require("node:fs"); const plan = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); for (const entry of plan.modules) console.log(entry.moduleName);' "$current_plan_json")
}

default_parallel_jobs() {
  local cpu_count=""

  cpu_count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')"
  if ! [[ "$cpu_count" =~ ^[0-9]+$ ]] || (( cpu_count < 1 )); then
    cpu_count=4
  fi
  if (( cpu_count > 4 )); then
    cpu_count=4
  fi
  printf '%s\n' "$cpu_count"
}

append_parallel_command() {
  local var_name="$1"
  shift
  local rendered=""

  printf -v rendered '%q ' "$@"
  printf -v "$var_name" '%s%s\n' "${!var_name}" "${rendered% }"
}

run_parallel_commands() {
  local commands="$1"
  local max_jobs="$2"
  local temp_root=""
  local next_command=""
  local finished_pid=""
  local wait_status=0
  declare -A pid_to_log=()
  declare -A pid_to_command=()

  if [[ -z "$commands" ]]; then
    return 0
  fi

  if (( max_jobs <= 1 )); then
    while IFS= read -r command; do
      [[ -z "$command" ]] && continue
      (
        set -euo pipefail
        eval "$command"
      )
    done <<< "$commands"
    return 0
  fi

  temp_root="$(mktemp -d)"

  start_job() {
    local task_command="$1"
    local task_log="$temp_root/job.$$.${RANDOM}.log"

    (
      set -euo pipefail
      eval "$task_command"
    ) >"$task_log" 2>&1 &

    pid_to_log[$!]="$task_log"
    pid_to_command[$!]="$task_command"
  }

  finish_one_job() {
    local finished_command=""
    local finished_log_path=""

    finished_pid=""
    if wait -n -p finished_pid; then
      wait_status=0
    else
      wait_status=$?
    fi

    finished_log_path="${pid_to_log[$finished_pid]:-}"
    finished_command="${pid_to_command[$finished_pid]:-}"
    unset 'pid_to_log[$finished_pid]'
    unset 'pid_to_command[$finished_pid]'

    if (( wait_status != 0 )); then
      printf 'selfhost-native-verify: parallel command failed: %s\n' "$finished_command" >&2
      if [[ -n "$finished_log_path" && -f "$finished_log_path" ]]; then
        cat "$finished_log_path" >&2
      fi
      for finished_pid in "${!pid_to_command[@]}"; do
        kill "$finished_pid" >/dev/null 2>&1 || true
      done
      for finished_pid in "${!pid_to_command[@]}"; do
        wait "$finished_pid" >/dev/null 2>&1 || true
      done
      rm -rf "$temp_root"
      return "$wait_status"
    fi

    rm -f "$finished_log_path"
    return 0
  }

  while IFS= read -r next_command || [[ -n "$next_command" ]]; do
    [[ -z "$next_command" ]] && continue
    while (( ${#pid_to_command[@]} >= max_jobs )); do
      finish_one_job || return $?
    done
    start_job "$next_command"
  done <<< "$commands"

  while (( ${#pid_to_command[@]} > 0 )); do
    finish_one_job || return $?
  done

  rm -rf "$temp_root"
}

assert_json_equal() {
  local left_path="$1"
  local right_path="$2"

  node - "$left_path" "$right_path" <<'JS'
const fs = require("node:fs");

const renames = {
  stage2CompilerModule: "candidateCompilerModule",
  compilerSnapshotStage2Module: "compilerSnapshotCandidateModule",
  stage2EmittedModule: "candidateEmittedModule",
  stage2CheckOutput: "candidateCheckOutput",
  stage2ExplainOutput: "candidateExplainOutput",
  stage2NativeOutput: "candidateNativeOutput",
};

function normalize(value) {
  if (Array.isArray(value)) {
    return value.map(normalize);
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [renames[key] || key, normalize(item)]),
    );
  }
  if (typeof value === "string") {
    let text = value;
    for (const [left, right] of Object.entries(renames)) {
      text = text.split(left).join(right);
    }
    return text;
  }
  return value;
}

const leftPath = process.argv[2];
const rightPath = process.argv[3];
const leftValue = normalize(JSON.parse(fs.readFileSync(leftPath, "utf8")));
const rightValue = normalize(JSON.parse(fs.readFileSync(rightPath, "utf8")));

if (JSON.stringify(leftValue) !== JSON.stringify(rightValue)) {
  console.error(`selfhost-native-verify: JSON mismatch between ${leftPath} and ${rightPath}`);
  process.exit(1);
}
JS
}

run_verify() {
  local parallel_jobs="${CLASP_NATIVE_VERIFY_JOBS:-$(default_parallel_jobs)}"
  local full_verify_project_entry_arg="--project-entry=$project_root/src/Main.clasp"
  local fast_verify_fixture_root="$verify_root/fast-project"
  local fast_verify_entry_path="$fast_verify_fixture_root/Main.clasp"
  local fast_verify_project_entry_arg="--project-entry=$fast_verify_entry_path"
  local export_commands=""
  local promoted_build_plan_path="$verify_root/promoted.source.native-image.build-plan.txt"
  local rebuilt_build_plan_path="$verify_root/rebuilt.source.native-image.build-plan.txt"
  local promoted_build_plan_json="$verify_root/promoted.source.native-image.build-plan.json"
  local previous_build_plan_json="$verify_cache_root/full-native-image/build-plan.json"
  local promoted_module_decl_root="$verify_root/promoted.source.native-image.decls"
  local rebuilt_module_decl_root="$verify_root/rebuilt.source.native-image.decls"
  local incremental_modules_path="$verify_root/rebuilt.source.native-image.changed-modules.txt"
  local incremental_module_count="0"
  local verify_summary=""

  case "$verify_mode" in
    fast|full)
      ;;
    *)
      printf 'selfhost-native-verify: unsupported mode: %s\n' "$verify_mode" >&2
      return 1
      ;;
  esac

  cd "$project_root"
  mkdir -p "$verify_root"

  if [[ "$verify_mode" == "fast" ]]; then
    mkdir -p "$fast_verify_fixture_root"
    cat > "$fast_verify_entry_path" <<'EOF'
module Main

import Helper

main : Str
main = helper "fast-verify"
EOF
    cat > "$fast_verify_fixture_root/Helper.clasp" <<'EOF'
module Helper

helper : Str -> Str
helper value = value
EOF
  fi

  if [[ "$verify_mode" == "full" ]]; then
    append_parallel_command export_commands run_native_export "$embedded_native_path" checkProjectText "$full_verify_project_entry_arg" "$verify_root/promoted.source.check.txt"
    append_parallel_command export_commands run_native_export "$embedded_compiler_native_path" checkProjectText "$full_verify_project_entry_arg" "$verify_root/rebuilt.source.check.txt"
    append_parallel_command export_commands run_native_export "$embedded_native_path" checkCoreProjectText "$full_verify_project_entry_arg" "$verify_root/promoted.source.check-core.json"
    append_parallel_command export_commands run_native_export "$embedded_compiler_native_path" checkCoreProjectText "$full_verify_project_entry_arg" "$verify_root/rebuilt.source.check-core.json"
    append_parallel_command export_commands run_native_export "$embedded_native_path" compileProjectText "$full_verify_project_entry_arg" "$verify_root/promoted.source.compile.mjs"
    append_parallel_command export_commands run_native_export "$embedded_compiler_native_path" compileProjectText "$full_verify_project_entry_arg" "$verify_root/rebuilt.source.compile.mjs"
    append_parallel_command export_commands run_native_export "$embedded_native_path" nativeProjectText "$full_verify_project_entry_arg" "$verify_root/promoted.source.native.ir"
    append_parallel_command export_commands run_native_export "$embedded_compiler_native_path" nativeProjectText "$full_verify_project_entry_arg" "$verify_root/rebuilt.source.native.ir"
    append_parallel_command export_commands run_native_export "$embedded_native_path" nativeImageProjectBuildPlanText "$full_verify_project_entry_arg" "$promoted_build_plan_path"
    append_parallel_command export_commands run_native_export "$embedded_compiler_native_path" nativeImageProjectBuildPlanText "$full_verify_project_entry_arg" "$rebuilt_build_plan_path"
  else
    append_parallel_command export_commands run_native_export "$embedded_compiler_native_path" checkProjectText "$fast_verify_project_entry_arg" "$verify_root/promoted.compiler.check.txt"
  fi

  run_parallel_commands "$export_commands" "$parallel_jobs"

  if [[ "$verify_mode" == "full" ]]; then
    cmp -s "$verify_root/promoted.source.check.txt" "$verify_root/rebuilt.source.check.txt"
    cmp -s "$verify_root/promoted.source.check-core.json" "$verify_root/rebuilt.source.check-core.json"
    cmp -s "$verify_root/promoted.source.compile.mjs" "$verify_root/rebuilt.source.compile.mjs"
    cmp -s "$verify_root/promoted.source.native.ir" "$verify_root/rebuilt.source.native.ir"
    cmp -s "$promoted_build_plan_path" "$rebuilt_build_plan_path"
    parse_native_image_build_plan "$promoted_build_plan_path" "$promoted_build_plan_json"
    mkdir -p "$promoted_module_decl_root" "$rebuilt_module_decl_root"
    export_commands=""
    while IFS= read -r module_name || [[ -n "$module_name" ]]; do
      [[ -z "$module_name" ]] && continue
      append_parallel_command export_commands run_native_export "$embedded_native_path" nativeImageProjectModuleDeclsText "$full_verify_project_entry_arg" "$module_name" "$promoted_module_decl_root/$module_name.json"
    done < <(node -e 'const fs = require("node:fs"); const plan = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); for (const entry of plan.modules) console.log(entry.moduleName);' "$promoted_build_plan_json")
    run_parallel_commands "$export_commands" "$parallel_jobs"
    compute_incremental_verify_modules "$promoted_build_plan_json" "$previous_build_plan_json" "$promoted_module_decl_root" "$verify_cache_root" "$incremental_modules_path"
    incremental_module_count="$(grep -cve '^$' "$incremental_modules_path" || true)"

    export_commands=""
    while IFS= read -r module_name || [[ -n "$module_name" ]]; do
      [[ -z "$module_name" ]] && continue
      append_parallel_command export_commands run_native_export "$embedded_compiler_native_path" nativeImageProjectModuleDeclsText "$full_verify_project_entry_arg" "$module_name" "$rebuilt_module_decl_root/$module_name.json"
    done < "$incremental_modules_path"
    run_parallel_commands "$export_commands" "$parallel_jobs"

    while IFS= read -r module_name || [[ -n "$module_name" ]]; do
      [[ -z "$module_name" ]] && continue
      cmp -s "$promoted_module_decl_root/$module_name.json" "$rebuilt_module_decl_root/$module_name.json"
    done < "$incremental_modules_path"

    refresh_full_verify_cache "$promoted_build_plan_json" "$promoted_module_decl_root"
    verify_summary="{\"mode\":\"full\",\"nativeSourceCheckMatchesPromoted\":true,\"nativeSourceCheckCoreMatchesPromoted\":true,\"nativeSourceCompileMatchesPromoted\":true,\"nativeSourceIrMatchesPromoted\":true,\"nativeSourceImageBuildPlanMatchesPromoted\":true,\"nativeSourceChangedModuleDeclsMatchPromoted\":true,\"nativeSourceChangedModuleCount\":$incremental_module_count}"
  else
    test -s "$verify_root/promoted.compiler.check.txt"
    verify_summary='{"mode":"fast","promotedCompilerFixtureCheckExecutes":true}'
  fi

  printf '%s\n' "$verify_summary"
}

if [[ "${CLASP_NATIVE_VERIFY_LOCK_HELD:-0}" != "1" ]]; then
  acquire_verify_lock
  export CLASP_NATIVE_VERIFY_LOCK_HELD=1
fi

if [[ -n "${IN_NIX_SHELL:-}" ]]; then
  if [[ "$verify_mode" == "full" ]]; then
    run_verify | tail -n 1 | grep -F '"mode":"full","nativeSourceCheckMatchesPromoted":true,"nativeSourceCheckCoreMatchesPromoted":true,"nativeSourceCompileMatchesPromoted":true,"nativeSourceIrMatchesPromoted":true,"nativeSourceImageBuildPlanMatchesPromoted":true,"nativeSourceChangedModuleDeclsMatchPromoted":true'
  else
    run_verify | tail -n 1 | grep -F '"mode":"fast","promotedCompilerFixtureCheckExecutes":true'
  fi
else
  nix develop "$project_root" --command bash -lc "
    set -euo pipefail
    export CLASP_PROJECT_ROOT=\"$project_root\"
    export CLASP_NATIVE_VERIFY_MODE=\"$verify_mode\"
    export CLASP_NATIVE_VERIFY_LOCK_FILE=\"$verify_lock_file\"
    export CLASP_NATIVE_VERIFY_LOCK_HELD=\"${CLASP_NATIVE_VERIFY_LOCK_HELD:-0}\"
    bash src/scripts/verify.sh
  "
fi
