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
foreign_safety_module="$test_root/foreign-interop-safety.mjs"
compiled_process_module="$test_root/compiled-process.mjs"
safe_package_module="$test_root/safe-package-foreign.clasp"
compiled_safe_package_module="$test_root/safe-package-foreign.mjs"
unsafe_runtime_module="$test_root/unsafe-runtime-foreign.clasp"
unsafe_runtime_module_output="$test_root/unsafe-runtime-foreign.mjs"
unsafe_runtime_check_output="$test_root/unsafe-runtime-check.out"
unsafe_runtime_compile_output="$test_root/unsafe-runtime-compile.out"
unsafe_name_module="$test_root/unsafe-name-foreign.clasp"
unsafe_name_check_output="$test_root/unsafe-name-check.out"

cleanup() {
  if [[ "${CLASP_TEST_KEEP_TMP:-}" == "1" ]]; then
    printf 'kept test root: %s\n' "$test_root" >&2
  else
    rm -rf "$test_root" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

timeout "$timeout_secs" node --input-type=module - "$project_root" "$program_module" "$foreign_safety_module" <<'NODE'
import fs from "node:fs";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import path from "node:path";

const [projectRoot, programPath, foreignSafetyPath] = process.argv.slice(2);
const emitterPath = path.join(projectRoot, "src/Compiler/Emit/JavaScript.clasp");
const checkerPath = path.join(projectRoot, "src/Compiler/Checker.clasp");
const frontendDriverPath = path.join(projectRoot, "src/Compiler/Driver/Frontend.clasp");
const nativeEmitterPath = path.join(projectRoot, "src/Compiler/Emit/Native.clasp");
const runtimePath = path.join(projectRoot, "runtime/clasp_runtime.rs");
const emitterSource = fs.readFileSync(emitterPath, "utf8");
const checkerSource = fs.readFileSync(checkerPath, "utf8");
const frontendDriverSource = fs.readFileSync(frontendDriverPath, "utf8");
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
assert(
  emitterSource.includes("jsIdentifierIsSafe : Str -> Bool") &&
    emitterSource.includes("emitJsIdentifier : Str -> Str") &&
    emitterSource.includes("emitJsIdentifier (foreignDeclRuntimeName foreignDecl)") &&
    emitterSource.includes("emitJsString specifier") &&
    emitterSource.includes("emitJsString (foreignDeclSignature foreignDecl)"),
  "JS emitter should validate package-import identifiers and encode foreign metadata strings",
);
assert(
  emitterSource.includes("emitHostBindingEntry foreignDecl =") &&
    emitterSource.includes("emitJsString (foreignDeclName foreignDecl)") &&
    emitterSource.includes("emitJsString (foreignDeclRuntimeName foreignDecl)") &&
    emitterSource.includes("emitPackageBindingEntry foreignDecl ="),
  "JS host binding manifests should encode foreign names and package binding keys",
);
assert(
  checkerSource.includes("moduleForeignInteropValidationError : HostedModuleAst -> Str") &&
    checkerSource.includes("Package foreign import runtime name") &&
    checkerSource.includes("must be a safe JavaScript identifier"),
  "checker should reject unsafe JavaScript foreign/package import identifiers",
);
assert(
  frontendDriverSource.includes("frontendDriverCompileCheckedModuleText : HostedModuleAst -> [LowerDeclText] -> Str") &&
    frontendDriverSource.includes('textConcat ["ERROR:", summary]') &&
    frontendDriverSource.includes('textConcat ["ERROR:", message]'),
  "frontend compile driver should fail closed on checker and project errors",
);
assert(
  nativeEmitterSource.includes("emitNativeStringLiteral : Str -> Str") &&
    nativeEmitterSource.includes('textConcat ["string(", encode value, ")"]') &&
    nativeEmitterSource.includes("emitNativeMetadataField : Str -> Str -> Str") &&
    nativeEmitterSource.includes("runtimeBinding{"),
  "native text emitter should encode string literals and custom runtime binding metadata",
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

const foreignName = "safeForeign";
const foreignRuntimeName = "safeRuntime";
const foreignSpecifier = "local-\"pkg\nname";
const foreignDeclarationPath = "./decls/\"lead\nindex.d.ts";
const foreignSignature = "export declare function safeRuntime(value: string): string;\n// \"quoted\"";
const safePackageBinding = "$claspPackageBinding_safeForeign";
const encodedInteropModule = [
  `import { ${foreignRuntimeName} as ${safePackageBinding} } from ${JSON.stringify(foreignSpecifier)};`,
  "const $claspIdentityCodec = Object.freeze({ fromHost(value) { return value; }, toHost(value) { return value; } });",
  "export const __claspHostBindings = [",
  "  {",
  `    name: ${JSON.stringify(foreignName)},`,
  `    runtimeName: ${JSON.stringify(foreignRuntimeName)},`,
  `    source: { kind: "npm", specifier: ${JSON.stringify(foreignSpecifier)} },`,
  `    declaration: { path: ${JSON.stringify(foreignDeclarationPath)}, signature: ${JSON.stringify(foreignSignature)} },`,
  "    params: [$claspIdentityCodec],",
  "    returns: $claspIdentityCodec",
  "  },",
  "];",
  "export const __claspPackageImports = [",
  `  { name: ${JSON.stringify(foreignName)}, runtimeName: ${JSON.stringify(foreignRuntimeName)}, kind: "npm", specifier: ${JSON.stringify(foreignSpecifier)}, declaration: { path: ${JSON.stringify(foreignDeclarationPath)}, signature: ${JSON.stringify(foreignSignature)} } },`,
  "];",
  "const __claspPackageBindings = Object.freeze({",
  `  ${JSON.stringify(foreignName)}: ${safePackageBinding},`,
  `  ${JSON.stringify(foreignRuntimeName)}: ${safePackageBinding},`,
  "});",
  `export function ${foreignName}(arg0) { return arg0; }`,
  "",
].join("\n");
fs.writeFileSync(foreignSafetyPath, encodedInteropModule);
const safetyCheck = spawnSync(process.execPath, ["--check", foreignSafetyPath], { encoding: "utf8" });
assert(
  safetyCheck.status === 0,
  `encoded foreign interop module should pass node --check:\n${safetyCheck.stderr}\n${safetyCheck.stdout}`,
);
assert(encodedInteropModule.includes(JSON.stringify(foreignSpecifier)), "foreign package specifier should be JSON encoded");
assert(encodedInteropModule.includes(JSON.stringify(foreignDeclarationPath)), "foreign declaration path should be JSON encoded");
assert(encodedInteropModule.includes(JSON.stringify(foreignSignature)), "foreign declaration signature should be JSON encoded");
assert(!encodedInteropModule.includes(`specifier: "${foreignSpecifier}"`), "foreign specifier must not be emitted raw");
assert(!encodedInteropModule.includes(`signature: "${foreignSignature}"`), "foreign signature must not be emitted raw");

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
  '  timeout: runCommandTimeoutRaw(".", 1000, ["node", "-e", "process.stdout.write(\'before-timeout\'); setTimeout(() => process.stdout.write(\'after-timeout\'), 2000)"])',
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

claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN CLASP_PROJECT_ROOT="$project_root" "$project_root/scripts/resolve-claspc.sh")"

mkdir -p "$test_root/node_modules/local-upper"
printf 'export declare function upperCase(value: string): string;\n' >"$test_root/node_modules/local-upper/index.d.ts"

cat >"$safe_package_module" <<'CLASP'
module Main

foreign upperCase : Str -> Str = "upperCase" from npm "local-upper" declaration "./node_modules/local-upper/index.d.ts"

main : Str
main = upperCase "lead"
CLASP

timeout "$timeout_secs" "$claspc_bin" --json compile "$safe_package_module" -o "$compiled_safe_package_module" >/dev/null
timeout "$timeout_secs" node --check "$compiled_safe_package_module" >/dev/null
grep -F 'import { upperCase as $claspPackageBinding_upperCase } from "local-upper";' "$compiled_safe_package_module" >/dev/null
grep -F 'name: "upperCase"' "$compiled_safe_package_module" >/dev/null
grep -F 'runtimeName: "upperCase"' "$compiled_safe_package_module" >/dev/null
grep -F 'specifier: "local-upper"' "$compiled_safe_package_module" >/dev/null

cat >"$unsafe_runtime_module" <<'CLASP'
module Main

foreign upperCase : Str -> Str = "bad-runtime" from npm "local-upper" declaration "./node_modules/local-upper/index.d.ts"

main : Str
main = "lead"
CLASP

if timeout "$timeout_secs" "$claspc_bin" --json check "$unsafe_runtime_module" >"$unsafe_runtime_check_output" 2>&1; then
  printf 'unsafe package foreign runtime name unexpectedly passed check\n' >&2
  exit 1
fi
grep -F 'Package foreign import runtime name `bad-runtime` must be a safe JavaScript identifier' "$unsafe_runtime_check_output" >/dev/null

if timeout "$timeout_secs" "$claspc_bin" --json compile "$unsafe_runtime_module" -o "$unsafe_runtime_module_output" >"$unsafe_runtime_compile_output" 2>&1; then
  printf 'unsafe package foreign runtime name unexpectedly compiled\n' >&2
  exit 1
fi
grep -F 'Package foreign import runtime name `bad-runtime` must be a safe JavaScript identifier' "$unsafe_runtime_compile_output" >/dev/null
if [[ -e "$unsafe_runtime_module_output" ]]; then
  printf 'unsafe package foreign compile wrote a target module: %s\n' "$unsafe_runtime_module_output" >&2
  exit 1
fi

cat >"$unsafe_name_module" <<'CLASP'
module Main

foreign bad-name : Str -> Str = "badName"

main : Str
main = "lead"
CLASP

if timeout "$timeout_secs" "$claspc_bin" --json check "$unsafe_name_module" >"$unsafe_name_check_output" 2>&1; then
  printf 'unsafe foreign declaration name unexpectedly passed check\n' >&2
  exit 1
fi
grep -F 'Foreign declaration name `bad-name` must be a safe JavaScript identifier' "$unsafe_name_check_output" >/dev/null

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
  ["node", "-e", "process.stdout.write('compiled-before-timeout'); setTimeout(() => process.stdout.write('compiled-after-timeout'), 2000)"],
);
const timeoutResult = processModule.runTimeout(timeoutCommand, 1000);
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
