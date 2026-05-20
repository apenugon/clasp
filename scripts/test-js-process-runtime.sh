#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_JS_PROCESS_RUNTIME_TIMEOUT_SECS:-60}"

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  printf 'CLASP_JS_PROCESS_RUNTIME_TIMEOUT_SECS must be a positive integer\n' >&2
  exit 1
fi

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-js-process-runtime.XXXXXX")"
program_module="$test_root/process-runtime.mjs"
compiled_process_module="$test_root/compiled-process.mjs"

cleanup() {
  if [[ "${CLASP_TEST_KEEP_TMP:-}" == "1" ]]; then
    printf 'kept test root: %s\n' "$test_root" >&2
  else
    rm -rf "$test_root" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

timeout "$timeout_secs" node --input-type=module - "$project_root" "$program_module" <<'NODE'
import fs from "node:fs";
import { pathToFileURL } from "node:url";
import path from "node:path";

const [projectRoot, programPath] = process.argv.slice(2);
const emitterPath = path.join(projectRoot, "src/Compiler/Emit/JavaScript.clasp");
const checkerPath = path.join(projectRoot, "src/Compiler/Checker.clasp");
const nativeEmitterPath = path.join(projectRoot, "src/Compiler/Emit/Native.clasp");
const runtimePath = path.join(projectRoot, "runtime/clasp_runtime.rs");
const emitterSource = fs.readFileSync(emitterPath, "utf8");
const checkerSource = fs.readFileSync(checkerPath, "utf8");
const nativeEmitterSource = fs.readFileSync(nativeEmitterPath, "utf8");
const runtimeSource = fs.readFileSync(runtimePath, "utf8");

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function extractClaspStringList(source, bindingName) {
  const marker = `${bindingName} =`;
  const markerIndex = source.indexOf(marker);
  assert(markerIndex >= 0, `missing ${bindingName}`);
  const start = source.indexOf("[", markerIndex);
  assert(start >= 0, `missing ${bindingName} list start`);

  let depth = 0;
  let inString = false;
  let escaped = false;
  let literalStart = -1;
  const values = [];

  for (let index = start; index < source.length; index += 1) {
    const ch = source[index];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch === "\\") {
        escaped = true;
      } else if (ch === "\"") {
        values.push(JSON.parse(source.slice(literalStart, index + 1)));
        inString = false;
      }
      continue;
    }
    if (ch === "\"") {
      inString = true;
      literalStart = index;
      continue;
    }
    if (ch === "[") {
      depth += 1;
      continue;
    }
    if (ch === "]") {
      depth -= 1;
      if (depth === 0) {
        return values;
      }
    }
  }
  throw new Error(`unterminated ${bindingName}`);
}

assert(
  emitterSource.includes('emitNodeProcessPrelude decls foreignDecls =') &&
    emitterSource.includes('import { spawnSync as $claspNodeSpawnSync } from \\"node:child_process\\";'),
  "JS emitter should conditionally import node:child_process for process builtins",
);
assert(
  emitterSource.includes('foreignDeclNeedsNodeProcessPrelude : HostedForeignDeclAst -> Bool') &&
    emitterSource.includes('moduleNeedsNodeProcessPreludeWithForeigns decls foreignDecls') &&
    emitterSource.includes('rendered = append rendered (emitNodeProcessPrelude decls foreignDecls)'),
  "JS emitter should include node:child_process when runtime foreigns target process builtins",
);
assert(
  emitterSource.includes('moduleNeedsBuiltinPreludeWithForeigns : [LowerDeclText] -> [HostedForeignDeclAst] -> Bool') &&
    emitterSource.includes('rendered = append rendered (emitBuiltinPrelude decls foreignDecls)') &&
    emitterSource.includes('const builtin = typeof $claspBuiltinRuntime !== \\"undefined\\" ? $claspBuiltinRuntime[name] : null;'),
  "runtime foreign calls should fall back to process builtins when no host runtime is installed",
);
assert(
  checkerSource.includes('TypeBinding "runCommandTimeoutJson" runCommandTimeoutJsonBuiltinType') &&
    checkerSource.includes('awaitWatchedProcessTimeoutJsonBuiltinType'),
  "checker should expose timeout process builtins",
);
assert(
  nativeEmitterSource.includes('runCommandTimeoutJson{runtime=runCommandTimeoutJson, symbol=clasp_rt_run_command_timeout_json') &&
    nativeEmitterSource.includes('awaitWatchedProcessTimeoutJson{runtime=awaitWatchedProcessTimeoutJson'),
  "native emitter should expose timeout runtime binding metadata",
);
assert(
  runtimeSource.includes('fn render_run_command_timeout_payload') &&
    runtimeSource.includes('pub unsafe extern "C" fn clasp_rt_run_command_timeout_json') &&
    runtimeSource.includes('("runCommandTimeoutJson", 3)'),
  "native runtime should implement and dispatch runCommandTimeoutJson",
);

const builtinPrelude = extractClaspStringList(emitterSource, "builtinPreludeLines").join("\n");
assert(builtinPrelude.includes("function runCommandJson"), "builtin prelude should include runCommandJson");
assert(
  builtinPrelude.includes("function runCommandTimeoutJson"),
  "builtin prelude should include runCommandTimeoutJson",
);
assert(
  builtinPrelude.includes("$claspRunCommandJsonNode"),
  "builtin prelude should include the Node process fallback",
);

const emittedModule = [
  'import { spawnSync as $claspNodeSpawnSync } from "node:child_process";',
  builtinPrelude,
  'const $claspIdentityCodec = Object.freeze({ fromHost(value) { return value; }, toHost(value) { return value; } });',
  'function $claspRuntime(name) {',
  '  const runtime = globalThis.__claspRuntime;',
  '  const binding = runtime && typeof runtime === "object" ? runtime[name] : null;',
  '  if (typeof binding === "function") { return binding; }',
  '  const builtin = typeof $claspBuiltinRuntime !== "undefined" ? $claspBuiltinRuntime[name] : null;',
  '  if (typeof builtin === "function") { return builtin; }',
  '  throw new Error(`Missing Clasp runtime binding: ${name}`);',
  '}',
  'const $claspHostBindingMap = Object.freeze({',
  '  runCommandRaw: { runtimeName: "runCommandJson", params: [$claspIdentityCodec, $claspIdentityCodec], returns: $claspIdentityCodec },',
  '  runCommandTimeoutRaw: { runtimeName: "runCommandTimeoutJson", params: [$claspIdentityCodec, $claspIdentityCodec, $claspIdentityCodec], returns: $claspIdentityCodec }',
  '});',
  'function $claspHostBinding(name) { const binding = $claspHostBindingMap[name]; if (!binding) { throw new Error(`Missing Clasp host binding manifest: ${name}`); } return binding; }',
  'function $claspCallHostBinding(name, args) {',
  '  const binding = $claspHostBinding(name);',
  '  const runtime = $claspRuntime(binding.runtimeName);',
  '  const hostArgs = binding.params.map((param, index) => param.toHost(args[index]));',
  '  return binding.returns.fromHost(runtime(...hostArgs));',
  '}',
  'function runCommandRaw(arg0, arg1) { return $claspCallHostBinding("runCommandRaw", [arg0, arg1]); }',
  'function runCommandTimeoutRaw(arg0, arg1, arg2) { return $claspCallHostBinding("runCommandTimeoutRaw", [arg0, arg1, arg2]); }',
  'export const main = Object.freeze({',
  '  ok: runCommandRaw(".", ["node", "-e", "process.stdout.write(\'node-out\'); process.stderr.write(\'node-err\'); process.exit(7)"]),',
  '  timeout: runCommandTimeoutRaw(".", 50, ["node", "-e", "process.stdout.write(\'before-timeout\'); setTimeout(() => process.stdout.write(\'after-timeout\'), 1000)"])',
  '});',
  '',
].join("\n");

fs.writeFileSync(programPath, emittedModule);
const program = await import(`${pathToFileURL(programPath).href}?cacheBust=${Date.now()}`);
const report = program.main;

assert(Array.isArray(report.ok) && report.ok[0] === "Ok", `runCommandJson returned ${JSON.stringify(report.ok)}`);
assert(
  Array.isArray(report.timeout) && report.timeout[0] === "Ok",
  `runCommandTimeoutJson returned ${JSON.stringify(report.timeout)}`,
);

const ok = JSON.parse(report.ok[1]);
const timeout = JSON.parse(report.timeout[1]);

assert(ok.exitCode === 7, `unexpected run exit code ${ok.exitCode}`);
assert(ok.stdout === "node-out", `unexpected run stdout ${JSON.stringify(ok.stdout)}`);
assert(ok.stderr === "node-err", `unexpected run stderr ${JSON.stringify(ok.stderr)}`);
assert(timeout.exitCode === 124, `unexpected timeout exit code ${timeout.exitCode}`);
assert(timeout.stdout === "before-timeout", `unexpected timeout stdout ${JSON.stringify(timeout.stdout)}`);
assert(timeout.stderr === "", `unexpected timeout stderr ${JSON.stringify(timeout.stderr)}`);
assert(timeout.timedOut === true, "timeout run should set timedOut");
assert(timeout.error === "timeout", `unexpected timeout error ${JSON.stringify(timeout.error)}`);
NODE

claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN "$project_root/scripts/resolve-claspc.sh")"

timeout "$timeout_secs" "$claspc_bin" --json compile "$project_root/examples/legal-assistant-appbench/Process.clasp" -o "$compiled_process_module" >/dev/null

timeout "$timeout_secs" node --input-type=module - "$compiled_process_module" <<'NODE'
import fs from "node:fs";
import { pathToFileURL } from "node:url";

const [compiledProcessModule] = process.argv.slice(2);

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

const compiledSource = fs.readFileSync(compiledProcessModule, "utf8");
assert(
  compiledSource.includes('node:child_process'),
  "real claspc compile output should import node:child_process for process runtime foreigns",
);
assert(
  compiledSource.includes("$claspRunCommandJsonNode") ||
    compiledSource.includes("$claspNodeProcessRunCommandJson"),
  "real claspc compile output should include the Node command runtime implementation",
);

delete globalThis.__claspRuntime;
const processModule = await import(`${pathToFileURL(compiledProcessModule).href}?cacheBust=${Date.now()}`);
const command = processModule.commandSpec(
  ".",
  ["node", "-e", "process.stdout.write('compiled-out'); process.stderr.write('compiled-err'); process.exit(7)"],
);
const ok = processModule.run(command);
assert(Array.isArray(ok) && ok[0] === "Ok", `compiled run returned ${JSON.stringify(ok)}`);
assert(ok[1].exitCode === 7, `unexpected compiled run exit code ${ok[1].exitCode}`);
assert(ok[1].stdout === "compiled-out", `unexpected compiled run stdout ${JSON.stringify(ok[1].stdout)}`);
assert(ok[1].stderr === "compiled-err", `unexpected compiled run stderr ${JSON.stringify(ok[1].stderr)}`);

const timeoutCommand = processModule.commandSpec(
  ".",
  ["node", "-e", "process.stdout.write('compiled-before-timeout'); setTimeout(() => process.stdout.write('compiled-after-timeout'), 1000)"],
);
const timeoutResult = processModule.runTimeout(timeoutCommand, 50);
assert(
  Array.isArray(timeoutResult) && timeoutResult[0] === "Ok",
  `compiled timeout returned ${JSON.stringify(timeoutResult)}`,
);
assert(timeoutResult[1].exitCode === 124, `unexpected compiled timeout exit code ${timeoutResult[1].exitCode}`);
assert(
  timeoutResult[1].stdout === "compiled-before-timeout",
  `unexpected compiled timeout stdout ${JSON.stringify(timeoutResult[1].stdout)}`,
);
assert(timeoutResult[1].stderr === "", `unexpected compiled timeout stderr ${JSON.stringify(timeoutResult[1].stderr)}`);
assert(timeoutResult[1].timedOut === true, "compiled timeout should set timedOut");
assert(timeoutResult[1].error === "timeout", `unexpected compiled timeout error ${JSON.stringify(timeoutResult[1].error)}`);
NODE

printf 'js-process-runtime-ok\n'
