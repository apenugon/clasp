#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
report_path="$test_root/native-incremental-report.json"
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
cat > "$output_path" <<'TIMING'
real 0.01
user 0.00
sys 0.00
TIMING
EOF
chmod +x "$test_root/bin/time"

cat > "$test_root/bin/fake-claspc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "--json" && "$2" == "check" ]]; then
  entry_path="$3"
  project_dir="$(cd "$(dirname "$entry_path")" && pwd)"
  user_path="$project_dir/Shared/User.clasp"
  printf '{"status":"ok"}\n'
  if grep -F '"operator"' "$user_path" >/dev/null; then
    cat >&2 <<TRACE
[claspc-cache] module-summary miss module=Shared.User path=$user_path
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

printf 'fake-claspc: unsupported invocation: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$test_root/bin/fake-claspc"

PATH="$test_root/bin:$PATH" \
CLASPC_BIN="$test_root/bin/fake-claspc" \
bash "$project_root/scripts/measure-native-incremental.sh" --assert --report "$report_path" >/dev/null

node - "$report_path" <<'EOF'
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
