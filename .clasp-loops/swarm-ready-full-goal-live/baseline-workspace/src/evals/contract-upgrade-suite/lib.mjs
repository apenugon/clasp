import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { execFileSync, spawn } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const suiteRoot = dirname(fileURLToPath(import.meta.url));
export const commonStartRoot = join(suiteRoot, "common", "start");
export const tasksRoot = join(suiteRoot, "tasks");
export const resultsRoot = join(suiteRoot, "results");
export const benchmarkModes = ["raw-repo", "file-hinted", "oracle"];
export const assistanceModes = ["raw-text", "compiler-owned-air"];

export function ensureResultsRoot() {
  mkdirSync(resultsRoot, { recursive: true });
}

export function listTaskIds() {
  return readdirSync(tasksRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort();
}

export function loadTask(taskId) {
  const taskRoot = join(tasksRoot, taskId);
  const manifestPath = join(taskRoot, "task.json");
  if (!existsSync(manifestPath)) {
    throw new Error(`unknown task id: ${taskId}`);
  }

  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  return {
    ...manifest,
    taskRoot,
    solutionRoot: join(taskRoot, "solution")
  };
}

export function attrValue(node, name) {
  return node?.attrs?.find((attr) => attr.name === name)?.value;
}

export function stableString(value) {
  return JSON.stringify(value, null, 2);
}

export function listFiles(root) {
  const out = [];
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const fullPath = join(root, entry.name);
    if (entry.isDirectory()) {
      out.push(...listFiles(fullPath));
    } else if (entry.isFile()) {
      out.push(fullPath);
    }
  }
  return out.sort();
}

export function schemaFieldType(schema) {
  if (!schema) {
    return "Unknown";
  }

  if (typeof schema.name === "string") {
    return schema.name;
  }

  switch (schema.kind) {
    case "str":
      return "Str";
    case "bool":
      return "Bool";
    case "int":
      return "Int";
    default:
      return schema.kind ?? "Unknown";
  }
}

export function findClaspc() {
  if (process.env.CLASP_CLASPC) {
    const explicit = resolve(process.cwd(), process.env.CLASP_CLASPC);
    if (!existsSync(explicit)) {
      throw new Error(`CLASP_CLASPC does not exist: ${explicit}`);
    }
    return explicit;
  }

  const repoRoot = resolve(suiteRoot, "../../../..");
  const fixed = resolve(
    repoRoot,
    "dist-newstyle/build/x86_64-linux/ghc-9.8.4/clasp-compiler-0.1.0.0/x/claspc/build/claspc/claspc"
  );
  if (existsSync(fixed)) {
    return fixed;
  }

  const discovered = execFileSync("find", [resolve(repoRoot, "dist-newstyle"), "-type", "f", "-name", "claspc"], {
    encoding: "utf8"
  })
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0)[0];

  if (!discovered) {
    throw new Error("could not locate a built claspc binary under dist-newstyle");
  }

  return discovered;
}

export function emitArtifacts(entryPath) {
  const claspc = findClaspc();
  const outputRoot = mkdtempSync(join(tmpdir(), "clasp-contract-upgrade-suite-"));
  const compiledPath = join(outputRoot, "candidate.js");
  const contextPath = join(outputRoot, "candidate.context.json");
  const airPath = join(outputRoot, "candidate.air.json");
  const repoRoot = resolve(suiteRoot, "../../../..");

  execFileSync(claspc, ["check", entryPath, "--compiler=bootstrap"], {
    cwd: repoRoot,
    stdio: "pipe",
    encoding: "utf8"
  });

  execFileSync(claspc, ["compile", entryPath, "-o", compiledPath, "--compiler=bootstrap"], {
    cwd: repoRoot,
    stdio: "pipe",
    encoding: "utf8"
  });

  execFileSync(claspc, ["context", entryPath, "-o", contextPath, "--compiler=bootstrap"], {
    cwd: repoRoot,
    stdio: "pipe",
    encoding: "utf8"
  });

  execFileSync(claspc, ["air", entryPath, "-o", airPath, "--compiler=bootstrap"], {
    cwd: repoRoot,
    stdio: "pipe",
    encoding: "utf8"
  });

  return { outputRoot, compiledPath, contextPath, airPath, claspc };
}

export async function loadCompiledModule(compiledPath) {
  return import(`${pathToFileURL(compiledPath).href}?t=${Date.now()}`);
}

function summarizeFields(fields) {
  return fields.map((field) => `${field.name}:${field.type}`).join(", ");
}

export function buildSemanticBrief(task, compiled, context, air) {
  const schemaTargets = context.nodes
    .filter((node) => node.kind === "schema" && attrValue(node, "builtin") !== true && task.semanticFocus.schemaNames.includes(attrValue(node, "name")))
    .map((node) => {
      const schemaName = attrValue(node, "name");
      const fieldNodes = context.nodes
        .filter((candidate) => candidate.kind === "schemaField" && attrValue(candidate, "schemaName") === schemaName)
        .map((candidate) => ({ name: attrValue(candidate, "name"), type: attrValue(candidate, "type") }))
        .sort((left, right) => left.name.localeCompare(right.name));
      return {
        name: schemaName,
        location: node.span?.file && node.span?.start?.line ? `${node.span.file}:${node.span.start.line}` : "unknown",
        fields: fieldNodes
      };
    });

  const routeTargets = context.nodes
    .filter((node) => node.kind === "route" && task.semanticFocus.routeNames.includes(attrValue(node, "name")))
    .map((node) => ({
      name: attrValue(node, "name"),
      location: node.span?.file && node.span?.start?.line ? `${node.span.file}:${node.span.start.line}` : "unknown",
      method: attrValue(node, "method"),
      path: attrValue(node, "path"),
      requestType: attrValue(node, "requestType"),
      responseType: attrValue(node, "responseType")
    }));

  const toolTargets = context.nodes
    .filter((node) => node.kind === "tool" && task.semanticFocus.toolNames.includes(attrValue(node, "name")))
    .map((node) => ({
      name: attrValue(node, "name"),
      location: node.span?.file && node.span?.start?.line ? `${node.span.file}:${node.span.start.line}` : "unknown",
      requestType: attrValue(node, "requestType"),
      responseType: attrValue(node, "responseType")
    }));

  const workflowTargets = compiled.__claspWorkflows
    .filter((workflow) => task.semanticFocus.workflowNames.includes(workflow.name))
    .map((workflow) => ({
      name: workflow.name,
      stateType: workflow.stateType
    }));

  const declTargets = air.nodes
    .filter((node) => node.kind === "decl" && task.semanticFocus.declNames.includes(attrValue(node, "name")))
    .map((node) => ({
      name: attrValue(node, "name"),
      type: node.type
    }));

  const absentSchemas = task.assertions?.schemas?.absent ?? [];
  const requiredSchemas = (task.assertions?.schemas?.present ?? []).map((schema) => ({
    name: schema.name,
    fields: schema.fields
  }));
  const toolAssertion = task.assertions?.tool ?? null;
  const routeAssertion = task.assertions?.route ?? null;
  const workflowAssertion = task.assertions?.workflow ?? null;

  const lines = [
    "# Clasp Semantic Brief",
    "Use this as the current typed dependency graph. Prefer it over rediscovering the same relationships from scratch.",
    "",
    "## Compiler-Known Current Surfaces",
    "Schemas:"
  ];

  for (const schema of schemaTargets) {
    lines.push(`- ${schema.name} @ ${schema.location} => { ${summarizeFields(schema.fields)} }`);
  }

  lines.push("Routes:");
  for (const route of routeTargets) {
    lines.push(`- ${route.name} @ ${route.location} => ${route.method} ${route.path} ${route.requestType} -> ${route.responseType}`);
  }

  lines.push("Tools:");
  for (const tool of toolTargets) {
    lines.push(`- ${tool.name} @ ${tool.location} => ${tool.requestType} -> ${tool.responseType}`);
  }

  lines.push("Workflows:");
  for (const workflow of workflowTargets) {
    lines.push(`- ${workflow.name} => state ${workflow.stateType}`);
  }

  lines.push("Decls:");
  for (const decl of declTargets) {
    lines.push(`- ${decl.name} : ${decl.type}`);
  }

  lines.push("");
  lines.push("## Verifier-Critical Targets");
  for (const schema of requiredSchemas) {
    lines.push(`- Required schema after edits: ${schema.name} => { ${summarizeFields(schema.fields)} }`);
  }
  for (const schemaName of absentSchemas) {
    lines.push(`- Remove old schema name from emitted artifacts: ${schemaName}`);
  }
  if (toolAssertion) {
    lines.push(
      `- Tool ${toolAssertion.name} must use ${toolAssertion.requestType} fields { ${summarizeFields(toolAssertion.requestFields)} } and return ${toolAssertion.responseType}`
    );
  }
  if (routeAssertion) {
    lines.push(`- Route ${routeAssertion.name} must return ${routeAssertion.responseType}`);
  }
  if (workflowAssertion) {
    lines.push(
      `- Workflow ${workflowAssertion.name} must keep state ${workflowAssertion.stateType}.${workflowAssertion.stateField}:${workflowAssertion.stateFieldType}`
    );
  }

  return lines.join("\n");
}

export function renderTaskMarkdown(task) {
  const requirementLines = task.requirements.map((requirement, index) => `${index + 1}. ${requirement}`);
  return [
    `# Task: ${task.title}`,
    "",
    task.overview,
    "",
    "## Requirements",
    ...requirementLines,
    "",
    "## Acceptance",
    "The task is complete when `bash scripts/verify.sh` passes."
  ].join("\n");
}

export function renderPrompt(task, mode, assistance, semanticBrief) {
  const intro = [
    "Benchmark harness instructions:",
    "- Work only inside the current workspace.",
    "- Do not inspect parent directories.",
    "- Prefer the smallest local edit set that satisfies the task.",
    "- Use the files in the workspace as the source of truth.",
    "- Run `bash scripts/verify.sh` before finishing.",
    "- Finish only after verification passes."
  ];

  const modeLines =
    mode === "raw-repo"
      ? [
          "## Working Guidance",
          "- Discover the relevant files from the workspace.",
          "- Do not assume the exact edit surface before reading the local files."
        ]
      : mode === "file-hinted"
        ? [
            "## Working Guidance",
            `- Likely edit surfaces: ${task.fileHints.map((file) => `\`${file}\``).join(", ")}.`,
            "- Keep the edit set focused unless verification exposes a broader issue."
          ]
        : [
            "## Working Guidance",
            ...task.oracleHints.map((hint) => `- ${hint}`),
            "- Stay on those surfaces unless verification exposes a compiler/runtime issue."
          ];

  const sections = [intro.join("\n"), renderTaskMarkdown(task), modeLines.join("\n")];

  if (assistance === "compiler-owned-air") {
    sections.push(
      [
        "## Compiler Guidance",
        "- The semantic brief below is compiler-derived from the current workspace.",
        "- Treat it as authoritative for scoping and type relationships unless verification proves otherwise.",
        "- Prefer editing the typed dependency chain it names before doing broader repo discovery.",
        "- Use existing source syntax in the workspace as the syntax reference."
      ].join("\n")
    );
    sections.push(semanticBrief);
  }

  return sections.join("\n\n");
}

export function buildWorkspaceGuide(task, mode) {
  const guidance =
    mode === "raw-repo"
      ? "Discover the relevant files from the workspace before editing."
      : mode === "file-hinted"
        ? `Likely edit surfaces: ${task.fileHints.join(", ")}.`
        : `Exact edit surfaces: ${task.fileHints.join(", ")}.`;

  return [
    "# Eval Workspace Instructions",
    "",
    "- Work only inside this workspace.",
    "- Do not inspect parent directories.",
    `- ${guidance}`,
    "- Prefer the smallest local edit set.",
    "- Run `bash scripts/verify.sh` before finishing.",
    "- Stop once the task is complete and verification passes."
  ].join("\n");
}

export function createWorkspace(task, mode, assistance, semanticBrief) {
  const workspace = mkdtempSync(join(tmpdir(), `clasp-contract-suite-${task.id}-${mode}-${assistance}-`));
  mkdirSync(join(workspace, "Shared"), { recursive: true });
  mkdirSync(join(workspace, "scripts"), { recursive: true });

  cpSync(join(commonStartRoot, "Main.clasp"), join(workspace, "Main.clasp"));
  cpSync(join(commonStartRoot, "Shared", "Lead.clasp"), join(workspace, "Shared", "Lead.clasp"));

  writeFileSync(join(workspace, "AGENTS.md"), buildWorkspaceGuide(task, mode) + "\n", "utf8");
  writeFileSync(join(workspace, "TASK.md"), renderTaskMarkdown(task) + "\n", "utf8");

  if (assistance === "compiler-owned-air") {
    writeFileSync(join(workspace, "CLASP_SEMANTIC_BRIEF.md"), semanticBrief + "\n", "utf8");
  }

  const verifyScript = `#!/usr/bin/env bash
set -euo pipefail

workspace_root="$(cd "$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
log_file="$workspace_root/benchmark-verify.jsonl"
started_ms="$(node -e 'process.stdout.write(String(Date.now()))')"
set +e
output="$(bash "${join(suiteRoot, "validate.sh")}" "${task.id}" "$workspace_root" 2>&1)"
status=$?
set -e
ended_ms="$(node -e 'process.stdout.write(String(Date.now()))')"
printf '%s\\n' "$output"
node -e 'const fs = require("fs"); fs.appendFileSync(process.argv[1], JSON.stringify({ startedAtMs: Number(process.argv[2]), endedAtMs: Number(process.argv[3]), exitCode: Number(process.argv[4]) }) + "\\n");' "$log_file" "$started_ms" "$ended_ms" "$status"
exit "$status"
`;
  writeFileSync(join(workspace, "scripts", "verify.sh"), verifyScript, { encoding: "utf8", mode: 0o755 });

  return workspace;
}

export function parseCodexUsage(agentLogPath) {
  const lines = readFileSync(agentLogPath, "utf8")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line));
  const completion = [...lines].reverse().find((line) => line.type === "turn.completed");

  if (!completion?.usage) {
    return {
      prompt: null,
      completion: null,
      retry: 0,
      debug: 0,
      total: null,
      complete: false,
      harnessUsage: {
        provider: "codex",
        inputTokens: null,
        cachedInputTokens: null,
        outputTokens: null,
        uncachedInputTokens: null,
        uncachedTotal: null
      }
    };
  }

  const input = Number(completion.usage.input_tokens ?? 0);
  const cachedInput = Number(completion.usage.cached_input_tokens ?? 0);
  const output = Number(completion.usage.output_tokens ?? 0);

  return {
    prompt: input,
    completion: output,
    retry: 0,
    debug: 0,
    total: input + output,
    complete: true,
    harnessUsage: {
      provider: "codex",
      inputTokens: input,
      cachedInputTokens: cachedInput,
      outputTokens: output,
      uncachedInputTokens: Math.max(0, input - cachedInput),
      uncachedTotal: Math.max(0, input - cachedInput) + output
    }
  };
}

export function readJsonLines(filePath) {
  if (!existsSync(filePath)) {
    return [];
  }

  return readFileSync(filePath, "utf8")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line));
}

export function runCommand(command, args, options = {}) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd,
      env: options.env ?? process.env,
      stdio: options.stdio ?? ["ignore", "pipe", "pipe"]
    });

    let stdout = "";
    let stderr = "";

    if (child.stdout) {
      child.stdout.on("data", (chunk) => {
        stdout += chunk.toString();
      });
    }

    if (child.stderr) {
      child.stderr.on("data", (chunk) => {
        stderr += chunk.toString();
      });
    }

    child.on("error", reject);
    child.on("exit", (exitCode) => {
      resolvePromise({
        exitCode: exitCode ?? 1,
        stdout,
        stderr
      });
    });
  });
}

export function runCodex(promptText, workspace, agentLogPath, model, reasoningEffort) {
  return new Promise((resolvePromise, reject) => {
    const timeoutMs = Number.parseInt(process.env.CLASP_RUN_TIMEOUT_MS ?? "300000", 10);
    const child = spawn(
      "codex",
      [
        "exec",
        "--json",
        "-m",
        model,
        "-c",
        `model_reasoning_effort="${reasoningEffort}"`,
        "--skip-git-repo-check",
        "--cd",
        workspace,
        "--dangerously-bypass-approvals-and-sandbox",
        "-"
      ],
      {
        cwd: workspace,
        env: process.env,
        stdio: ["pipe", "pipe", "pipe"]
      }
    );

    const output = [];
    let timedOut = false;
    const timeoutHandle = Number.isFinite(timeoutMs) && timeoutMs > 0
      ? setTimeout(() => {
          timedOut = true;
          child.kill("SIGTERM");
          setTimeout(() => child.kill("SIGKILL"), 1000).unref();
        }, timeoutMs)
      : null;

    child.stdout.on("data", (chunk) => {
      const text = chunk.toString();
      output.push(text);
      writeFileSync(agentLogPath, output.join(""), "utf8");
    });
    child.stderr.on("data", (chunk) => {
      process.stderr.write(chunk);
    });
    child.stdin.end(promptText);

    child.on("error", reject);
    child.on("exit", (exitCode) => {
      if (timeoutHandle) {
        clearTimeout(timeoutHandle);
      }
      resolvePromise({
        exitCode: exitCode ?? (timedOut ? 124 : 1),
        timedOut
      });
    });
  });
}

export function changedFilesAgainstStart(workspace) {
  return listFiles(commonStartRoot)
    .filter((file) => file.endsWith(".clasp"))
    .map((file) => relative(commonStartRoot, file))
    .filter((relativePath) => readFileSync(join(commonStartRoot, relativePath), "utf8") !== readFileSync(join(workspace, relativePath), "utf8"));
}

export function summarizeVerifyLog(entries, startedAtMs) {
  const successful = entries.find((entry) => entry.exitCode === 0);
  return {
    verifyAttempts: entries.length,
    repairLoops: successful ? Math.max(0, entries.length - 1) : entries.length,
    timeToGreenMs: successful ? successful.endedAtMs - startedAtMs : null,
    verifyEvents: entries
  };
}

export function average(values) {
  if (values.length === 0) {
    return null;
  }
  return Math.round(values.reduce((sum, value) => sum + value, 0) / values.length);
}

export function median(values) {
  if (values.length === 0) {
    return null;
  }
  const sorted = [...values].sort((left, right) => left - right);
  const middle = Math.floor(sorted.length / 2);
  if (sorted.length % 2 === 1) {
    return sorted[middle];
  }
  return Math.round((sorted[middle - 1] + sorted[middle]) / 2);
}

export function cleanupArtifacts(artifacts) {
  if (artifacts?.outputRoot) {
    rmSync(artifacts.outputRoot, { recursive: true, force: true });
  }
}

export function validateCandidate(task, candidateDir, compiled, context, air) {
  const issues = [];
  const ensure = (condition, message) => {
    if (!condition) {
      issues.push(message);
    }
  };

  const route = compiled.__claspRoutes.find((candidate) => candidate.name === task.assertions.route.name);
  const tool = compiled.__claspTools.find((candidate) => candidate.name === task.assertions.tool.name);
  const workflow = compiled.__claspWorkflows.find((candidate) => candidate.name === task.assertions.workflow.name);

  ensure(route, `missing ${task.assertions.route.name} route contract`);
  ensure(tool, `missing ${task.assertions.tool.name} tool contract`);
  ensure(workflow, `missing ${task.assertions.workflow.name} workflow contract`);

  ensure(compiled.main === task.expectedMain, `expected compiled main to be ${JSON.stringify(task.expectedMain)}, got ${JSON.stringify(compiled.main)}`);

  for (const schemaName of task.assertions.schemas.absent) {
    ensure(!(schemaName in compiled.__claspSchemas), `expected ${schemaName} schema to be removed`);
  }

  for (const schemaExpectation of task.assertions.schemas.present) {
    const schemaDecl = compiled.__claspSchemas[schemaExpectation.name]?.schema;
    ensure(schemaDecl, `expected ${schemaExpectation.name} schema to exist`);
    if (schemaDecl) {
      const actualFields = Object.keys(schemaDecl.fields).sort();
      const expectedFields = schemaExpectation.fields.map((field) => field.name).sort();
      ensure(
        JSON.stringify(actualFields) === JSON.stringify(expectedFields),
        `unexpected ${schemaExpectation.name} fields: ${actualFields.join(", ")}`
      );
      for (const field of schemaExpectation.fields) {
        ensure(
          schemaFieldType(schemaDecl.fields[field.name]?.schema) === field.type,
          `expected ${schemaExpectation.name}.${field.name} to be ${field.type}`
        );
      }
    }
  }

  if (tool?.requestSchema) {
    const actualFields = Object.keys(tool.requestSchema.fields).sort();
    const expectedFields = task.assertions.tool.requestFields.map((field) => field.name).sort();
    ensure(
      JSON.stringify(actualFields) === JSON.stringify(expectedFields),
      `unexpected ${task.assertions.tool.requestType} fields: ${actualFields.join(", ")}`
    );
    for (const field of task.assertions.tool.requestFields) {
      ensure(
        schemaFieldType(tool.requestSchema.fields[field.name]?.schema) === field.type,
        `expected ${task.assertions.tool.requestType}.${field.name} to be ${field.type}`
      );
    }
  }

  if (route) {
    ensure(route.responseType === task.assertions.route.responseType, `expected route response type ${task.assertions.route.responseType}, got ${route.responseType}`);
    ensure(route.responseDecl?.schema?.name === task.assertions.route.responseType, `expected route response schema ${task.assertions.route.responseType}`);
  }

  if (tool) {
    ensure(tool.requestType === task.assertions.tool.requestType, `expected tool request type ${task.assertions.tool.requestType}, got ${tool.requestType}`);
    ensure(tool.responseType === task.assertions.tool.responseType, `expected tool response type ${task.assertions.tool.responseType}, got ${tool.responseType}`);
  }

  if (workflow) {
    ensure(workflow.stateType === task.assertions.workflow.stateType, `expected workflow state type ${task.assertions.workflow.stateType}, got ${workflow.stateType}`);
  }

  ensure(
    schemaFieldType(compiled.__claspSchemas[task.assertions.workflow.stateType]?.schema?.fields[task.assertions.workflow.stateField]?.schema) === task.assertions.workflow.stateFieldType,
    `expected ${task.assertions.workflow.stateType}.${task.assertions.workflow.stateField} to reference ${task.assertions.workflow.stateFieldType}`
  );

  const contextNodeIds = new Set(context.nodes.map((node) => node.id));
  for (const nodeId of task.assertions.context.requiredNodes) {
    ensure(contextNodeIds.has(nodeId), `context graph is missing ${nodeId}`);
  }
  for (const nodeId of task.assertions.context.absentNodes) {
    ensure(!contextNodeIds.has(nodeId), `context graph should not contain ${nodeId}`);
  }

  const contextRoute = context.nodes.find((node) => node.id === `route:${task.assertions.route.name}`);
  const contextTool = context.nodes.find((node) => node.id === `tool:${task.assertions.tool.name}`);
  if (contextRoute) {
    ensure(attrValue(contextRoute, "responseType") === task.assertions.route.responseType, `context route responseType should be ${task.assertions.route.responseType}`);
  }
  if (contextTool) {
    ensure(attrValue(contextTool, "requestType") === task.assertions.tool.requestType, `context tool requestType should be ${task.assertions.tool.requestType}`);
  }

  const routeResponseEdge = context.edges.find(
    (edge) =>
      edge.from === task.assertions.context.routeResponseEdge.routeId &&
      edge.kind === "route-response-schema" &&
      edge.to === task.assertions.context.routeResponseEdge.schemaId
  );
  ensure(routeResponseEdge, `context graph is missing the route-response-schema edge to ${task.assertions.context.routeResponseEdge.schemaId}`);

  const airRootIds = new Set(air.roots);
  for (const rootId of task.assertions.air.requiredRoots) {
    ensure(airRootIds.has(rootId), `AIR roots are missing ${rootId}`);
  }
  for (const rootId of task.assertions.air.absentRoots) {
    ensure(!airRootIds.has(rootId), `AIR roots should not contain ${rootId}`);
  }

  const primarySchema = task.assertions.schemas.present[0];
  const primaryFields = primarySchema
    ? primarySchema.fields.map((field) => field.name)
    : [];

  if (issues.length > 0) {
    return {
      status: "error",
      taskId: task.id,
      candidateDir,
      issueCount: issues.length,
      issues
    };
  }

  return {
    status: "ok",
    taskId: task.id,
    candidateDir,
    main: compiled.main,
    routeResponseType: route?.responseType ?? null,
    toolRequestFields: task.assertions.tool.requestFields.map((field) => field.name),
    workflowStateType: workflow?.stateType ?? null,
    primarySchema: primarySchema?.name ?? null,
    primaryFields
  };
}
