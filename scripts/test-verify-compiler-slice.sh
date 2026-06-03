#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
bash_bin="$(command -v bash)"
test_root=""

cleanup() {
  rm -rf "${test_root:-}"
}

trap cleanup EXIT

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-verify-compiler-slice.XXXXXX")"
project_copy="$test_root/project"
mkdir -p "$project_copy/scripts" "$project_copy/examples" "$test_root/bin"

cp "$project_root/scripts/verify-compiler-slice.sh" "$project_copy/scripts/verify-compiler-slice.sh"
cp "$project_root/scripts/resolve-claspc.sh" "$project_copy/scripts/resolve-claspc.sh"
cp "$project_root/scripts/normalize-tmpdir.sh" "$project_copy/scripts/normalize-tmpdir.sh"

cat >"$test_root/bin/fake-claspc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${CLASP_TEST_FAKE_CLASPC_LOG:-}" ]]; then
  printf '%s\n' "$*" >>"$CLASP_TEST_FAKE_CLASPC_LOG"
fi

json_mode=0
if [[ "${1:-}" == "--json" ]]; then
  json_mode=1
  shift
fi

command="${1:-}"
entry="${2:-}"

if [[ "$json_mode" == "1" && "$command" == "check" ]]; then
  case "$entry" in
    examples/compiler-parser.clasp)
      printf '{"status":"ok","implementation":"clasp-native","summary":"parseModuleSummary : Str -> ParserState"}\n'
      ;;
    examples/compiler-checker.clasp)
      printf '{"status":"ok","implementation":"clasp-native","summary":"snapshot : CheckSnapshot"}\n'
      ;;
    examples/compiler-lower.clasp)
      printf '{"status":"ok","implementation":"clasp-native","summary":"lowerExpr : CheckedExprText -> LowerExprText"}\n'
      ;;
    examples/compiler-emitter.clasp)
      printf '{"status":"ok","implementation":"clasp-native","summary":"emitModule : [LowerDeclText] -> Str"}\n'
      ;;
    examples/compiler-ergonomics.clasp)
      printf '{"status":"ok","implementation":"clasp-native","summary":"snapshot : ErgonomicsSnapshot"}\n'
      ;;
    *)
      printf 'unexpected check entry: %s\n' "$entry" >&2
      exit 1
      ;;
  esac
  exit 0
fi

if [[ "$json_mode" == "0" && "$command" == "run" ]]; then
  case "$entry" in
    examples/compiler-parser.clasp)
      printf '{"moduleName":"Compiler.Parser","imports":"|Compiler.Loader|Compiler.Renderers","signatures":"|parseModule : Str -> Str|main : Str","declarations":"|parseModule source|main"}\n'
      ;;
    examples/compiler-checker.clasp)
      printf '{"roster":"ok:[Str]","matrix":"ok:[[Int]]","mixed":"error:expected Str but found Int","nestedPattern":"accepted:Ada|rejected|none","wildcardPattern":"any"}\n'
      ;;
    examples/compiler-lower.clasp)
      printf '{"listExpr":"list:[literal:Ada, literal:Grace]","letExpr":"let names = list:[literal:Ada, literal:Grace] in call renderNames(name:names)","callExpr":"call score(int:7, name:weight)"}\n'
      ;;
    examples/compiler-emitter.clasp)
      printf '{"arrayLiteral":"[\\"Ada\\", \\"Grace\\", \\"Linus\\"]","moduleText":"export const names = [\\"Ada\\", \\"Grace\\", \\"Linus\\"];\\nexport function renderNames(names) { return JSON.stringify(names); }"}\n'
      ;;
    examples/compiler-ergonomics.clasp)
      printf '{"selectedId":"repair","selectedStatus":"running","statusLookup":"running","queueCount":1,"blockerCount":0,"boxValue":"running","loopSummary":"alpha!,beta!","summary":"repair:running:running:unblocked"}\n'
      ;;
    *)
      printf 'unexpected run entry: %s\n' "$entry" >&2
      exit 1
      ;;
  esac
  exit 0
fi

printf 'unexpected fake-claspc invocation: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$test_root/bin/fake-claspc"

CLASP_PROJECT_ROOT="$project_copy" "$bash_bin" "$project_copy/scripts/verify-compiler-slice.sh" --help |
  grep -F 'usage: scripts/verify-compiler-slice.sh' >/dev/null
CLASP_PROJECT_ROOT="$project_copy" "$bash_bin" "$project_copy/scripts/verify-compiler-slice.sh" --help |
  grep -F -- '--check-only' >/dev/null
CLASP_PROJECT_ROOT="$project_copy" "$bash_bin" "$project_copy/scripts/verify-compiler-slice.sh" --list |
  grep -F 'lower' >/dev/null
CLASP_PROJECT_ROOT="$project_copy" "$bash_bin" "$project_copy/scripts/verify-compiler-slice.sh" --list |
  grep -F 'ergonomics' >/dev/null

check_only_log="$test_root/check-only.log"
CLASP_PROJECT_ROOT="$project_copy" \
  CLASP_CLASPC="$test_root/bin/fake-claspc" \
  CLASP_TEST_FAKE_CLASPC_LOG="$check_only_log" \
  "$bash_bin" "$project_copy/scripts/verify-compiler-slice.sh" --check-only checker |
  grep -F 'verify-compiler-slice: ok (checker, check-only)' >/dev/null

grep -F -- '--json check examples/compiler-checker.clasp' "$check_only_log" >/dev/null
if grep -F -- 'run examples/compiler-checker.clasp' "$check_only_log" >/dev/null; then
  printf 'check-only focused verifier should not run compiler fixture\n' >&2
  exit 1
fi
if grep -F 'compiler-parser.clasp' "$check_only_log" >/dev/null; then
  printf 'check-only checker verifier should not run parser fixture\n' >&2
  exit 1
fi

checker_log="$test_root/checker.log"
CLASP_PROJECT_ROOT="$project_copy" \
  CLASP_CLASPC="$test_root/bin/fake-claspc" \
  CLASP_TEST_FAKE_CLASPC_LOG="$checker_log" \
  "$bash_bin" "$project_copy/scripts/verify-compiler-slice.sh" checker |
  grep -F 'verify-compiler-slice: ok (checker)' >/dev/null

grep -F -- '--json check examples/compiler-checker.clasp' "$checker_log" >/dev/null
grep -F -- 'run examples/compiler-checker.clasp' "$checker_log" >/dev/null
if grep -F 'compiler-parser.clasp' "$checker_log" >/dev/null; then
  printf 'checker-only focused verifier should not run parser fixture\n' >&2
  exit 1
fi

all_log="$test_root/all.log"
CLASP_PROJECT_ROOT="$project_copy" \
  CLASP_CLASPC="$test_root/bin/fake-claspc" \
  CLASP_TEST_FAKE_CLASPC_LOG="$all_log" \
  CLASP_COMPILER_SLICE_TIMEOUT_SECS=3 \
  "$bash_bin" "$project_copy/scripts/verify-compiler-slice.sh" all |
  grep -F 'verify-compiler-slice: ok (parser checker lower emitter ergonomics)' >/dev/null
ergonomics_log="$test_root/ergonomics.log"
CLASP_PROJECT_ROOT="$project_copy" \
  CLASP_CLASPC="$test_root/bin/fake-claspc" \
  CLASP_TEST_FAKE_CLASPC_LOG="$ergonomics_log" \
  "$bash_bin" "$project_copy/scripts/verify-compiler-slice.sh" ergonomics |
  grep -F 'verify-compiler-slice: ok (ergonomics)' >/dev/null

grep -F -- '--json check examples/compiler-parser.clasp' "$all_log" >/dev/null
grep -F -- '--json check examples/compiler-checker.clasp' "$all_log" >/dev/null
grep -F -- '--json check examples/compiler-lower.clasp' "$all_log" >/dev/null
grep -F -- '--json check examples/compiler-emitter.clasp' "$all_log" >/dev/null
grep -F -- '--json check examples/compiler-ergonomics.clasp' "$all_log" >/dev/null
grep -F -- 'run examples/compiler-parser.clasp' "$all_log" >/dev/null
grep -F -- 'run examples/compiler-checker.clasp' "$all_log" >/dev/null
grep -F -- 'run examples/compiler-lower.clasp' "$all_log" >/dev/null
grep -F -- 'run examples/compiler-emitter.clasp' "$all_log" >/dev/null
grep -F -- 'run examples/compiler-ergonomics.clasp' "$all_log" >/dev/null
grep -F -- '--json check examples/compiler-ergonomics.clasp' "$ergonomics_log" >/dev/null
grep -F -- 'run examples/compiler-ergonomics.clasp' "$ergonomics_log" >/dev/null
