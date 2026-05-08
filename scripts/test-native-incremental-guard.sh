#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
native_report_path="$test_root/native-incremental-report.json"
selfhost_report_path="$test_root/selfhost-incremental-report.json"
bad_native_log="$test_root/bad-native.log"
bad_check_log="$test_root/bad-check.log"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

mkdir -p "$test_root/bin"

cat > "$test_root/bin/time" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      shift
      ;;
    -o)
      output_path="${2:-}"
      shift 2
      ;;
    *)
      break
      ;;
  esac
done

if [[ -z "$output_path" ]]; then
  printf 'fake-time: missing -o <path>\n' >&2
  exit 1
fi

"$@"
real_seconds="${FAKE_TIME_REAL_SECONDS:-0.01}"
{
  printf 'real %s\n' "$real_seconds"
  printf 'user 0.00\n'
  printf 'sys 0.00\n'
} > "$output_path"
EOF
chmod +x "$test_root/bin/time"

cat > "$test_root/bin/fake-claspc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "--json" && "$2" == "check" ]]; then
  entry_path="$3"
  project_dir="$(cd "$(dirname "$entry_path")" && pwd)"
  helper_path="$project_dir/Helper.clasp"
  if [[ -f "$helper_path" ]]; then
    printf '{"status":"ok"}\n'
    if grep -F '"hullo"' "$helper_path" >/dev/null; then
      cat >&2 <<TRACE
[claspc-cache] module-summary validated-hit module=Helper path=$helper_path
[claspc-cache] module-summary hit module=Main path=$entry_path
TRACE
    else
      cat >&2 <<TRACE
[claspc-cache] module-summary miss module=Helper path=$helper_path
[claspc-cache] module-summary miss module=Main path=$entry_path
TRACE
    fi
    exit 0
  fi

  user_path="$project_dir/Shared/User.clasp"
  printf '{"status":"ok"}\n'
    if grep -F '"operator"' "$user_path" >/dev/null; then
      cat >&2 <<TRACE
[claspc-cache] module-summary validated-hit module=Shared.User path=$user_path
[claspc-cache] module-summary hit module=Shared.Render path=$project_dir/Shared/Render.clasp
[claspc-cache] module-summary hit module=Main path=$entry_path
TRACE
  else
    cat >&2 <<TRACE
[claspc-cache] module-summary miss module=Shared.User path=$user_path
[claspc-cache] module-summary miss module=Shared.Render path=$project_dir/Shared/Render.clasp
[claspc-cache] module-summary miss module=Main path=$entry_path
TRACE
  fi
  exit 0
fi

if [[ "$1" == "native-image" ]]; then
  entry_path="$2"
  if [[ "${3:-}" != "-o" || -z "${4:-}" ]]; then
    printf 'fake-claspc: unsupported native-image invocation: %s\n' "$*" >&2
    exit 1
  fi
  output_path="$4"
  project_dir="$(cd "$(dirname "$entry_path")" && pwd)"
  user_path="$project_dir/Shared/User.clasp"
  printf '{"image":"ok"}\n' > "$output_path"
  if grep -F '"operator"' "$user_path" >/dev/null; then
    cat >&2 <<TRACE
[claspc-cache] native-image miss path=$output_path
[claspc-cache] build-plan hit path=$output_path
[claspc-cache] decl-module miss module=Shared.User path=$user_path
[claspc-cache] decl-module hit module=Shared.Render path=$project_dir/Shared/Render.clasp
[claspc-cache] decl-module hit module=Main path=$entry_path
TRACE
  else
    cat >&2 <<TRACE
[claspc-cache] native-image miss path=$output_path
[claspc-cache] build-plan miss path=$output_path
[claspc-cache] decl-module miss module=Shared.User path=$user_path
[claspc-cache] decl-module miss module=Shared.Render path=$project_dir/Shared/Render.clasp
[claspc-cache] decl-module miss module=Main path=$entry_path
TRACE
  fi
  exit 0
fi

if [[ "$1" == "exec-image" ]]; then
  image_path="$2"
  export_name="$3"
  entry_arg="$4"
  output_path="$5"
  if [[ "$image_path" != *"/embedded.compiler.native.image.json" || "$export_name" != "nativeImageProjectText" || "$entry_arg" != --project-entry=* ]]; then
    printf 'fake-claspc: unsupported exec-image invocation: %s\n' "$*" >&2
    exit 1
  fi
  entry_path="${entry_arg#--project-entry=}"
  project_dir="$(cd "$(dirname "$entry_path")" && pwd)"
  helper_path="$project_dir/Helper.clasp"
  printf '{"image":"ok"}\n' > "$output_path"
  if grep -F '"hullo"' "$helper_path" >/dev/null; then
    cat >&2 <<TRACE
[claspc-cache] source-export miss export=nativeImageProjectText path=$entry_path
[claspc-cache] build-plan hit path=$entry_path
[claspc-cache] decl-module miss module=Helper path=$helper_path
[claspc-cache] decl-module hit module=Main path=$entry_path
TRACE
  else
    cat >&2 <<TRACE
[claspc-cache] source-export miss export=nativeImageProjectText path=$entry_path
[claspc-cache] build-plan miss path=$entry_path
[claspc-cache] decl-module miss module=Helper path=$helper_path
[claspc-cache] decl-module miss module=Main path=$entry_path
TRACE
  fi
  exit 0
fi

printf 'fake-claspc: unsupported invocation: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$test_root/bin/fake-claspc"

PATH="$test_root/bin:$PATH" \
CLASP_CLASPC="$test_root/bin/fake-claspc" \
CLASPC_BIN="$test_root/bin/fake-claspc" \
bash "$project_root/scripts/measure-native-incremental.sh" --assert --report "$native_report_path" >/dev/null

node - "$native_report_path" <<'EOF'
const fs = require("node:fs");

const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (report.scenario !== "native-cli-body-change") {
  throw new Error(`unexpected scenario: ${report.scenario}`);
}
if (!report.matchesExpectations) {
  throw new Error(`expected passing guard: ${report.mismatches.join("; ")}`);
}
if (JSON.stringify(report.changedModules) !== JSON.stringify(["Shared.User"])) {
  throw new Error(`unexpected expected changed modules: ${JSON.stringify(report.changedModules)}`);
}
if (JSON.stringify(report.observedChangedModules) !== JSON.stringify(["Shared.User"])) {
  throw new Error(`unexpected observed changed modules: ${JSON.stringify(report.observedChangedModules)}`);
}
if (report.observedCacheBehavior.nativeImage?.declModule?.Main !== "hit") {
  throw new Error("expected Main decl-module cache hit");
}
if (report.observedCacheBehavior.check?.moduleSummary?.Main !== "hit") {
  throw new Error("expected Main module-summary cache hit");
}
if (report.advisoryTimings.nativeImageCold?.realSeconds !== 0.01) {
  throw new Error(`unexpected advisory timing: ${report.advisoryTimings.nativeImageCold?.realSeconds}`);
}
EOF

PATH="$test_root/bin:$PATH" \
CLASP_CLASPC="$test_root/bin/fake-claspc" \
CLASPC_BIN="$test_root/bin/fake-claspc" \
bash "$project_root/scripts/measure-native-incremental.sh" \
  --scenario selfhost-body-change \
  --assert \
  --report "$selfhost_report_path" >/dev/null

node - "$selfhost_report_path" <<'EOF'
const fs = require("node:fs");

const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (report.scenario !== "selfhost-body-change") {
  throw new Error(`unexpected selfhost scenario: ${report.scenario}`);
}
if (!report.matchesExpectations) {
  throw new Error(`expected passing selfhost guard: ${report.mismatches.join("; ")}`);
}
if (JSON.stringify(report.observedChangedModules) !== JSON.stringify(["Helper"])) {
  throw new Error(`unexpected selfhost observed changed modules: ${JSON.stringify(report.observedChangedModules)}`);
}
if (report.expectedCacheBehavior.image?.sourceExport?.nativeImageProjectText !== "miss") {
  throw new Error("expected selfhost source-export cache expectation");
}
if (report.observedCacheBehavior.check?.moduleSummary?.Helper !== "validated-hit") {
  throw new Error("expected Helper module-summary validated hit");
}
if (report.observedCacheBehavior.image?.declModule?.Main !== "hit") {
  throw new Error("expected Main decl-module cache hit");
}
if (report.advisoryTimings.checkBodyChange?.realSeconds !== 0.01) {
  throw new Error(`unexpected selfhost check body-change timing: ${report.advisoryTimings.checkBodyChange?.realSeconds}`);
}
if (report.advisoryTimings.imageBodyChange?.realSeconds !== 0.01) {
  throw new Error(`unexpected selfhost image body-change timing: ${report.advisoryTimings.imageBodyChange?.realSeconds}`);
}
EOF

cat > "$bad_native_log" <<'EOF'
[claspc-cache] native-image miss path=/tmp/native-image.json
[claspc-cache] build-plan hit path=/tmp/native-image.json
[claspc-cache] decl-module miss module=Shared.User path=/tmp/Shared/User.clasp
[claspc-cache] decl-module miss module=Main path=/tmp/Main.clasp
[claspc-cache] decl-module hit module=Shared.Render path=/tmp/Shared/Render.clasp
EOF

cat > "$bad_check_log" <<'EOF'
[claspc-cache] module-summary miss module=Shared.User path=/tmp/Shared/User.clasp
[claspc-cache] module-summary miss module=Main path=/tmp/Main.clasp
[claspc-cache] module-summary hit module=Shared.Render path=/tmp/Shared/Render.clasp
EOF

if node "$project_root/scripts/native-incremental-guard.mjs" \
  native-cli-body-change \
  --native-log "$bad_native_log" \
  --check-log "$bad_check_log" \
  --assert >/dev/null 2>&1; then
  printf 'native incremental guard unexpectedly accepted an extra changed module\n' >&2
  exit 1
fi

if PATH="$test_root/bin:$PATH" \
  CLASP_CLASPC="$test_root/bin/fake-claspc" \
  CLASPC_BIN="$test_root/bin/fake-claspc" \
  FAKE_TIME_REAL_SECONDS=0.25 \
  bash "$project_root/scripts/measure-native-incremental.sh" \
    --assert \
    --max-duration nativeImageBodyChange=0.01 >/dev/null 2>&1; then
  printf 'native incremental guard unexpectedly accepted a body-change duration over the configured max\n' >&2
  exit 1
fi
