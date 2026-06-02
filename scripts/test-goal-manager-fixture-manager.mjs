#!/usr/bin/env node
"use strict";

const childProcess = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

function readJsonEnv(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  return JSON.parse(raw);
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function writeJson(filePath, value) {
  ensureDir(path.dirname(filePath));
  fs.writeFileSync(filePath, `${JSON.stringify(value)}\n`);
}

function readJsonFile(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function renderTemplateArg(value, replacements) {
  let rendered = value;
  for (const [needle, replacement] of Object.entries(replacements)) {
    rendered = rendered.split(needle).join(replacement);
  }
  return rendered;
}

function renderTemplate(template, replacements) {
  return template.map((arg) => renderTemplateArg(arg, replacements));
}

function templateContains(template, needle) {
  return template.some((arg) => String(arg).includes(needle));
}

function backendPromptTransport(template) {
  if (!Array.isArray(template) || template.length === 0) return "argument";
  const hasPromptPath = templateContains(template, "{prompt_path}");
  const hasInlinePrompt = templateContains(template, "{prompt}");
  if (hasPromptPath && hasInlinePrompt) return "prompt-path+inline";
  if (hasPromptPath) return "prompt-path";
  if (hasInlinePrompt) return "inline-prompt";
  return "missing";
}

function agentBackendSummary({ template, agentBin, agentModel, agentReasoning, agentSandbox, workspaceRoot }) {
  const isTemplate = Array.isArray(template) && template.length > 0;
  const promptTransport = backendPromptTransport(template);
  const hasRoleInput = !isTemplate || templateContains(template, "{role}");
  const hasPromptPathInput = !isTemplate || templateContains(template, "{prompt_path}");
  const hasInlinePromptInput = !isTemplate || templateContains(template, "{prompt}");
  const hasReportOutput = !isTemplate || templateContains(template, "{report_path}");
  const hasSchemaInput = !isTemplate || templateContains(template, "{schema_path}");
  const hasWorkspaceInput = !isTemplate || templateContains(template, "{workspace_root}");
  const hasModelInput = !isTemplate || templateContains(template, "{model}");
  const hasReasoningInput = !isTemplate || templateContains(template, "{reasoning}");
  let validationMessage = "";
  if (isTemplate && !hasRoleInput) {
    validationMessage = "agent-backend-template-missing-role";
  } else if (isTemplate && promptTransport === "missing") {
    validationMessage = "agent-backend-template-missing-prompt-input";
  } else if (isTemplate && !hasReportOutput) {
    validationMessage = "agent-backend-template-missing-report-output";
  }
  const warnings = [];
  if (isTemplate && !hasSchemaInput) warnings.push("agent-backend-template-missing-schema-path");
  if (isTemplate && !hasWorkspaceInput) warnings.push("agent-backend-template-missing-workspace-root");
  if (isTemplate && !hasModelInput) warnings.push("agent-backend-template-missing-model");
  if (isTemplate && !hasReasoningInput) warnings.push("agent-backend-template-missing-reasoning");
  return {
    kind: isTemplate ? "template" : "codex",
    agentBin,
    model: agentModel,
    reasoning: agentReasoning,
    sandbox: agentSandbox,
    workspaceRoot,
    templateArgCount: Array.isArray(template) ? template.length : 0,
    promptTransport,
    hasRoleInput,
    hasPromptPathInput,
    hasInlinePromptInput,
    hasReportOutput,
    hasSchemaInput,
    hasWorkspaceInput,
    hasModelInput,
    hasReasoningInput,
    valid: validationMessage === "",
    validationMessage,
    warnings,
  };
}

const agentBackendStandaloneRecommendedTemplate = [
  "{agent_bin}",
  "--role",
  "{role}",
  "--schema",
  "{schema_path}",
  "--report",
  "{report_path}",
  "--prompt-path",
  "{prompt_path}",
  "--workspace",
  "{workspace_root}",
  "--model",
  "{model}",
  "--reasoning",
  "{reasoning}",
  "--sandbox",
  "{sandbox}",
];

function agentBackendValidationMessages(summary) {
  if (summary.kind !== "template") return [];
  const messages = [];
  if (!summary.hasRoleInput) messages.push("agent-backend-template-missing-role");
  if (summary.promptTransport === "missing") messages.push("agent-backend-template-missing-prompt-input");
  if (!summary.hasReportOutput) messages.push("agent-backend-template-missing-report-output");
  return messages;
}

function agentBackendPolicyValidationMessages(policy, summary) {
  const messages = agentBackendValidationMessages(summary);
  if (!policy.allowCodexFallback && summary.kind === "codex") {
    messages.push("agent-backend-policy-disallows-codex-fallback");
  }
  if (policy.requirePromptPath && !summary.hasPromptPathInput) {
    messages.push("agent-backend-policy-requires-prompt-path");
  }
  if (policy.requireSchemaInput && !summary.hasSchemaInput) {
    messages.push("agent-backend-policy-requires-schema-path");
  }
  if (policy.requireWorkspaceInput && !summary.hasWorkspaceInput) {
    messages.push("agent-backend-policy-requires-workspace-root");
  }
  if (policy.requireModelInput && !summary.hasModelInput) {
    messages.push("agent-backend-policy-requires-model");
  }
  if (policy.requireReasoningInput && !summary.hasReasoningInput) {
    messages.push("agent-backend-policy-requires-reasoning");
  }
  return messages;
}

function agentBackendPolicyBlockingGap(message) {
  switch (message) {
    case "agent-backend-template-missing-role":
      return "backend template does not pass the agent role through {role}";
    case "agent-backend-template-missing-prompt-input":
      return "backend template does not pass the prompt through {prompt_path} or {prompt}";
    case "agent-backend-template-missing-report-output":
      return "backend template does not pass the structured report path through {report_path}";
    case "agent-backend-policy-disallows-codex-fallback":
      return "backend policy requires a configured non-Codex command template";
    case "agent-backend-policy-requires-prompt-path":
      return "backend policy requires durable prompt-path transport through {prompt_path}";
    case "agent-backend-policy-requires-schema-path":
      return "backend policy requires schema transport through {schema_path}";
    case "agent-backend-policy-requires-workspace-root":
      return "backend policy requires workspace transport through {workspace_root}";
    case "agent-backend-policy-requires-model":
      return "backend policy requires model transport through {model}";
    case "agent-backend-policy-requires-reasoning":
      return "backend policy requires reasoning transport through {reasoning}";
    default:
      return `backend policy failed with unknown validation message: ${message}`;
  }
}

function agentBackendPolicyRequiredClosure(message) {
  switch (message) {
    case "agent-backend-template-missing-role":
      return ["Add {role} to the backend command template arguments."];
    case "agent-backend-template-missing-prompt-input":
      return ["Add {prompt_path} for durable prompt transport or {prompt} for inline prompt transport."];
    case "agent-backend-template-missing-report-output":
      return ["Add {report_path} so the backend can write the required structured report."];
    case "agent-backend-policy-disallows-codex-fallback":
      return [
        "Set CLASP_LOOP_AGENT_COMMAND_JSON or CLASP_MANAGER_PLANNER_AGENT_COMMAND_JSON to a non-Codex backend template.",
        "Use agentBackendStandaloneRecommendedTemplate as the minimum command shape for standalone agents.",
      ];
    case "agent-backend-policy-requires-prompt-path":
      return ["Add {prompt_path} to the backend command template."];
    case "agent-backend-policy-requires-schema-path":
      return ["Add {schema_path} to the backend command template."];
    case "agent-backend-policy-requires-workspace-root":
      return ["Add {workspace_root} to the backend command template."];
    case "agent-backend-policy-requires-model":
      return ["Add {model} to the backend command template or relax the active backend policy."];
    case "agent-backend-policy-requires-reasoning":
      return ["Add {reasoning} to the backend command template or relax the active backend policy."];
    default:
      return ["Inspect the active AgentBackendPolicy and backend template placeholders."];
  }
}

function agentBackendPolicyMissingPlaceholders(policy, summary) {
  const missing = [];
  if (!summary.hasRoleInput) missing.push("{role}");
  if (!summary.hasReportOutput) missing.push("{report_path}");
  if ((policy.requirePromptPath && !summary.hasPromptPathInput) || summary.promptTransport === "missing") {
    missing.push("{prompt_path}");
  }
  if (policy.requireSchemaInput && !summary.hasSchemaInput) missing.push("{schema_path}");
  if (policy.requireWorkspaceInput && !summary.hasWorkspaceInput) missing.push("{workspace_root}");
  if (policy.requireModelInput && !summary.hasModelInput) missing.push("{model}");
  if (policy.requireReasoningInput && !summary.hasReasoningInput) missing.push("{reasoning}");
  if (!policy.allowCodexFallback && summary.kind === "codex") {
    return ["{agent_bin}", "{role}", "{schema_path}", "{report_path}", "{prompt_path}", "{workspace_root}"];
  }
  return Array.from(new Set(missing));
}

function agentBackendPolicySummary(policyName, policy, summary) {
  const validationMessages = agentBackendPolicyValidationMessages(policy, summary);
  return {
    policyName,
    backendKind: summary.kind,
    promptTransport: summary.promptTransport,
    valid: validationMessages.length === 0,
    validationMessage: validationMessages[0] || "",
    validationMessages,
    allowCodexFallback: policy.allowCodexFallback,
    requirePromptPath: policy.requirePromptPath,
    requireSchemaInput: policy.requireSchemaInput,
    requireWorkspaceInput: policy.requireWorkspaceInput,
    requireModelInput: policy.requireModelInput,
    requireReasoningInput: policy.requireReasoningInput,
    blockingGaps: validationMessages.map(agentBackendPolicyBlockingGap),
    requiredClosure: validationMessages.flatMap(agentBackendPolicyRequiredClosure),
    missingPlaceholders: agentBackendPolicyMissingPlaceholders(policy, summary),
    recommendedTemplate: agentBackendStandaloneRecommendedTemplate,
  };
}

function defaultBackendPolicy() {
  return {
    allowCodexFallback: true,
    requirePromptPath: false,
    requireSchemaInput: false,
    requireWorkspaceInput: false,
    requireModelInput: false,
    requireReasoningInput: false,
  };
}

function standaloneBackendPolicy() {
  return {
    allowCodexFallback: false,
    requirePromptPath: true,
    requireSchemaInput: true,
    requireWorkspaceInput: true,
    requireModelInput: false,
    requireReasoningInput: false,
  };
}

function plannerBackendPolicySummary(summary) {
  return agentBackendPolicySummary("default", defaultBackendPolicy(), summary);
}

function plannerBackendCapabilitySummary(summary) {
  const validationMessages = agentBackendPolicyValidationMessages(standaloneBackendPolicy(), summary);
  return {
    profileName: "local-clasp",
    backendKind: summary.kind,
    promptTransport: summary.promptTransport,
    standaloneReady: validationMessages.length === 0,
    roleCoverage: ["planner", "builder", "verifier"],
    supportsPlannerRole: true,
    supportsBuilderRole: true,
    supportsVerifierRole: true,
    supportsWorkspaceEdits: true,
    supportsChildTaskPlanning: true,
    supportsStructuredReports: true,
    requiresExternalModel: false,
    validationMessages,
    blockingGaps: validationMessages.map(agentBackendPolicyBlockingGap),
    requiredClosure: validationMessages.flatMap(agentBackendPolicyRequiredClosure),
  };
}

function runCommand(command, options) {
  const result = childProcess.spawnSync(command[0], command.slice(1), {
    cwd: options.cwd,
    env: options.env,
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
  });
  if (options.stdoutPath) fs.writeFileSync(options.stdoutPath, result.stdout || "");
  if (options.stderrPath) fs.writeFileSync(options.stderrPath, result.stderr || "");
  if (result.error) throw result.error;
  if (result.status !== 0) {
    const commandText = command.map((arg) => JSON.stringify(arg)).join(" ");
    throw new Error(`${options.label} failed with exit ${result.status}: ${commandText}\n${result.stderr || ""}`);
  }
}

function copyDirFiltered(sourceRoot, destinationRoot) {
  if (!fs.existsSync(sourceRoot)) return;
  fs.rmSync(destinationRoot, { recursive: true, force: true });
  ensureDir(destinationRoot);

  for (const entry of fs.readdirSync(sourceRoot, { withFileTypes: true })) {
    if (entry.name === ".clasp-test-tmp") continue;
    const sourcePath = path.join(sourceRoot, entry.name);
    const destinationPath = path.join(destinationRoot, entry.name);
    if (entry.isDirectory()) {
      copyDirFiltered(sourcePath, destinationPath);
    } else if (entry.isSymbolicLink()) {
      fs.symlinkSync(fs.readlinkSync(sourcePath), destinationPath);
    } else {
      ensureDir(path.dirname(destinationPath));
      fs.copyFileSync(sourcePath, destinationPath);
    }
  }
}

function taskDependencyEvidence(stateRoot, dependencies) {
  if (!Array.isArray(dependencies) || dependencies.length === 0) {
    return "No declared task dependencies.";
  }

  const lines = [];
  for (const taskId of dependencies) {
    const feedbackPath = path.join(stateRoot, `loop-${taskId}`, "feedback.json");
    if (fs.existsSync(feedbackPath)) {
      const report = readJsonFile(feedbackPath);
      lines.push(`- ${taskId} verifier=${report.verdict || ""} summary=${report.summary || ""}`);
    } else {
      lines.push(`- ${taskId} verifier=missing`);
    }
    lines.push("  builder=missing");
  }
  return lines.join("\n");
}

function defaultStatus() {
  return {
    state: {
      phase: "needs-planner",
      verdict: "pending",
      final: false,
    },
    plannedTaskIds: [],
    completedTaskIds: [],
    objectiveProjectedStatus: "needs-planner",
  };
}

function plannerPrompt(maxTaskLoops, goalText, stateRoot, workspaceRoot, plannerBackend, plannerBackendPolicy, plannerBackendCapability) {
  return [
    "You are the planner subagent for the Clasp repository.",
    "Plan the next bounded tasks needed to improve Clasp autonomously.",
    "Current wave: 1 of 1",
    "High-level goal:",
    goalText,
    "Current manager health/resource context:",
    `wave=1`,
    `stateRoot=${stateRoot}`,
    `taskWorkspaceRoot=${path.join(workspaceRoot, ".clasp-task-workspaces")}`,
    `Planner agent backend: kind=${plannerBackend.kind} promptTransport=${plannerBackend.promptTransport} valid=${plannerBackend.valid ? "true" : "false"}`,
    "Planner agent backend policy repair:",
    `policyName=${plannerBackendPolicy.policyName}`,
    `policyValid=${plannerBackendPolicy.valid ? "true" : "false"}`,
    `policyMessage=${plannerBackendPolicy.validationMessage}`,
    `policyMessages=${plannerBackendPolicy.validationMessages.join(",")}`,
    `policyBlockingGaps=${plannerBackendPolicy.blockingGaps.join(" | ")}`,
    `policyRequiredClosure=${plannerBackendPolicy.requiredClosure.join(" | ")}`,
    `policyMissingPlaceholders=${plannerBackendPolicy.missingPlaceholders.join(",")}`,
    `policyRecommendedTemplate=${plannerBackendPolicy.recommendedTemplate.join(" ")}`,
    "Planner agent backend capability repair:",
    `capabilityProfile=${plannerBackendCapability.profileName} backendKind=${plannerBackendCapability.backendKind} promptTransport=${plannerBackendCapability.promptTransport} standaloneReady=${plannerBackendCapability.standaloneReady ? "true" : "false"} roleCoverage=${plannerBackendCapability.roleCoverage.join(",")}`,
    `capabilitySupports=planner:${plannerBackendCapability.supportsPlannerRole ? "true" : "false"} builder:${plannerBackendCapability.supportsBuilderRole ? "true" : "false"} verifier:${plannerBackendCapability.supportsVerifierRole ? "true" : "false"} workspaceEdits:${plannerBackendCapability.supportsWorkspaceEdits ? "true" : "false"} childTaskPlanning:${plannerBackendCapability.supportsChildTaskPlanning ? "true" : "false"} structuredReports:${plannerBackendCapability.supportsStructuredReports ? "true" : "false"} externalModel:${plannerBackendCapability.requiresExternalModel ? "true" : "false"}`,
    `capabilityMessages=${plannerBackendCapability.validationMessages.join(",")}`,
    `capabilityBlockingGaps=${plannerBackendCapability.blockingGaps.join(" | ")}`,
    `capabilityRequiredClosure=${plannerBackendCapability.requiredClosure.join(" | ")}`,
    "Planner context pack:",
    "task: planner-1 status=ready ready=true attempts=0",
    "objective: fixture-manager manager-action=plan manager-task=planner-1 manager-task-status=ready",
    `spawn policy: parent= depth=0/1 children=0/${maxTaskLoops} remaining-child-budget=${maxTaskLoops}`,
    "child task ids:",
    "- none",
    "ready tasks: planner-1",
    "mailbox: runs=0 artifacts=0 memory=0 latest-run=/ latest-verifier=/",
    "planner task memory matches:",
    "- none",
    "objective memory matches:",
    "- none",
    "planner run trace:",
    "- none",
    "artifact paths:",
    "- none",
    "Planning is a control-plane step, not a verification or implementation step.",
    "Do not run repo-wide verification, benchmarks, builds, package installs, or other long commands from the planner.",
    "Do not inspect files, run shell commands, invoke tools, or gather extra repository context from the planner.",
    "Use only this prompt, the manager health context, and the benchmark summary as planner inputs.",
    "Return JSON matching the planner schema.",
    "Return the final planner-report JSON immediately; do not stream interim plans or empty task lists.",
    `Plan 1-${maxTaskLoops} bounded tasks with explicit dependencies and task prompts.`,
    "Each planned task must include an explicit role and a coordinationFocus list.",
  ].join("\n");
}

function main() {
  const stateRoot = process.argv.slice(2).join("/") || "swarm-native-goal-manager-state";
  const statusPath = path.join(stateRoot, "status.json");

  if (process.env.CLASP_MANAGER_COMMAND === "status" || process.env.CLASP_LOOP_COMMAND === "status") {
    if (fs.existsSync(statusPath)) {
      process.stdout.write(fs.readFileSync(statusPath, "utf8"));
    } else {
      process.stdout.write(`${JSON.stringify(defaultStatus())}\n`);
    }
    return;
  }

  const workspaceRoot = readJsonEnv("CLASP_LOOP_WORKSPACE_JSON", ".");
  const managerProjectRoot = readJsonEnv("CLASP_MANAGER_PROJECT_ROOT_JSON", process.cwd());
  const goalText = readJsonEnv(
    "CLASP_MANAGER_GOAL_JSON",
    "Improve Clasp by planning bounded native compiler/runtime/language tasks and closing them with ordinary Clasp loops.",
  );
  const objectiveId = readJsonEnv("CLASP_MANAGER_OBJECTIVE_ID_JSON", "fixture-manager");
  const maxTaskLoops = readJsonEnv("CLASP_MANAGER_MAX_TASKS_JSON", 1);
  const plannerTemplate = readJsonEnv(
    "CLASP_MANAGER_PLANNER_AGENT_COMMAND_JSON",
    readJsonEnv("CLASP_LOOP_AGENT_COMMAND_JSON", []),
  );
  const codexBin = readJsonEnv("CLASP_LOOP_CODEX_BIN_JSON", readJsonEnv("CLASP_LOOP_AGENT_BIN_JSON", "codex"));
  const agentBin = readJsonEnv("CLASP_LOOP_AGENT_BIN_JSON", codexBin);
  const agentModel = readJsonEnv("CLASP_LOOP_AGENT_MODEL_JSON", readJsonEnv("CLASP_LOOP_CODEX_MODEL_JSON", "gpt-5.5"));
  const agentReasoning = readJsonEnv(
    "CLASP_LOOP_AGENT_REASONING_JSON",
    readJsonEnv("CLASP_LOOP_CODEX_REASONING_JSON", "xhigh"),
  );
  const agentSandbox = readJsonEnv(
    "CLASP_LOOP_AGENT_SANDBOX_JSON",
    readJsonEnv("CLASP_LOOP_CODEX_SANDBOX_JSON", "danger-full-access"),
  );
  const managerClaspcBin = readJsonEnv("CLASP_MANAGER_CLASPC_BIN_JSON", "claspc");
  const childLoopProgram = readJsonEnv("CLASP_MANAGER_CHILD_LOOP_JSON", "examples/feedback-loop/Main.clasp");
  const plannerBackend = agentBackendSummary({
    template: plannerTemplate,
    agentBin,
    agentModel,
    agentReasoning,
    agentSandbox,
    workspaceRoot,
  });
  const plannerBackendPolicy = plannerBackendPolicySummary(plannerBackend);
  const plannerBackendCapability = plannerBackendCapabilitySummary(plannerBackend);

  ensureDir(stateRoot);
  ensureDir(workspaceRoot);

  if (!plannerBackend.valid) {
    const state = {
      phase: "planner-failed",
      verdict: "fail",
      final: true,
    };
    const status = {
      objectiveId,
      state,
      plannedTaskIds: [],
      completedTaskIds: [],
      objectiveProjectedStatus: "failed",
      plannerBackend,
      plannerBackendPolicy,
      plannerBackendCapability,
      failure: `planner backend config invalid: ${plannerBackend.validationMessage}`,
    };
    writeJson(statusPath, status);
    process.stdout.write(`${JSON.stringify(status)}\n`);
    return;
  }

  const plannerReportPath = path.join(stateRoot, "planner-1.json");
  const plannerPromptPath = path.join(stateRoot, "planner-1.prompt.txt");
  const plannerSchemaPath = readJsonEnv(
    "CLASP_MANAGER_PLANNER_SCHEMA_JSON",
    path.join(managerProjectRoot, "agents/schemas/planner-report.schema.json"),
  );
  const plannerStdoutPath = path.join(stateRoot, "planner-1.stdout.log");
  const plannerStderrPath = path.join(stateRoot, "planner-1.stderr.log");
  const prompt = plannerPrompt(maxTaskLoops, goalText, stateRoot, workspaceRoot, plannerBackend, plannerBackendPolicy, plannerBackendCapability);
  fs.writeFileSync(plannerPromptPath, prompt);

  const replacements = {
    "{role}": "planner",
    "{schema_path}": plannerSchemaPath,
    "{report_path}": plannerReportPath,
    "{prompt_path}": plannerPromptPath,
    "{prompt}": prompt,
    "{workspace_root}": workspaceRoot,
    "{agent_bin}": agentBin,
    "{model}": agentModel,
    "{reasoning}": agentReasoning,
    "{sandbox}": agentSandbox,
  };

  const plannerCommand =
    plannerTemplate.length > 0
      ? renderTemplate(plannerTemplate, replacements)
      : [
          agentBin,
          "exec",
          "--json",
          "--cd",
          workspaceRoot,
          "-m",
          agentModel,
          "-c",
          `model_reasoning_effort="${agentReasoning}"`,
          "--skip-git-repo-check",
          "--sandbox",
          agentSandbox,
          "--ephemeral",
          "--output-schema",
          plannerSchemaPath,
          "-o",
          plannerReportPath,
          prompt,
        ];

  runCommand(plannerCommand, {
    cwd: managerProjectRoot,
    env: process.env,
    stdoutPath: plannerStdoutPath,
    stderrPath: plannerStderrPath,
    label: "planner command",
  });

  const plannerReport = readJsonFile(plannerReportPath);
  const tasks = Array.isArray(plannerReport.tasks) ? plannerReport.tasks.slice(0, maxTaskLoops) : [];
  const completedTaskIds = [];

  for (const task of tasks) {
    const taskId = task.taskId;
    const taskFile = path.join(stateRoot, `task-${taskId}.md`);
    const childStateRoot = path.join(stateRoot, `loop-${taskId}`);
    const childWorkspaceRoot = path.join(stateRoot, `workspace-${taskId}`);
    const finalWorkspaceRoot = path.join(workspaceRoot, ".clasp-task-workspaces", taskId);

    ensureDir(childStateRoot);
    ensureDir(childWorkspaceRoot);
    fs.writeFileSync(
      taskFile,
      [
        `taskId: ${task.taskId || ""}`,
        `role: ${task.role || ""}`,
        `detail: ${task.detail || ""}`,
        "prompt:",
        task.taskPrompt || "",
        "Dependency completion evidence:",
        taskDependencyEvidence(stateRoot, task.dependencies),
        "coordinationFocus:",
        ...(Array.isArray(task.coordinationFocus) ? task.coordinationFocus.map((item) => `- ${item}`) : []),
        "",
      ].join("\n"),
    );

    const childEnv = {
      ...process.env,
      CLASP_LOOP_TASK_FILE_JSON: JSON.stringify(taskFile),
      CLASP_LOOP_WORKSPACE_JSON: JSON.stringify(childWorkspaceRoot),
    };
    delete childEnv.CLASP_MANAGER_BENCHMARK_COMMAND_JSON;

    runCommand([managerClaspcBin, "run", childLoopProgram, "--", childStateRoot], {
      cwd: managerProjectRoot,
      env: childEnv,
      stdoutPath: path.join(childStateRoot, "loop.stdout.log"),
      stderrPath: path.join(childStateRoot, "loop.stderr.log"),
      label: `child loop ${taskId}`,
    });

    copyDirFiltered(childWorkspaceRoot, finalWorkspaceRoot);
    completedTaskIds.push(taskId);
  }

  const state = {
    attempt: 1,
    phase: "completed",
    verdict: "pass",
    completed: true,
    builderRuns: completedTaskIds.length,
    verifierRuns: completedTaskIds.length,
    healthy: true,
    needsAttention: false,
    attentionReason: "",
    final: true,
  };
  const feedbackPath = path.join(stateRoot, "feedback.json");
  const firstFeedbackPath =
    completedTaskIds.length > 0 ? path.join(stateRoot, `loop-${completedTaskIds[0]}`, "feedback.json") : "";
  const feedback = firstFeedbackPath && fs.existsSync(firstFeedbackPath)
    ? readJsonFile(firstFeedbackPath)
    : {
        verdict: "pass",
        summary: "fixture manager completed",
        findings: [],
        tests_run: ["goal manager fixture"],
        follow_up: [],
        capability_statuses: [],
      };
  const status = {
    objectiveId,
    state,
    plannerBackend,
    plannerBackendPolicy,
    plannerBackendCapability,
    plannedTaskIds: tasks.map((task) => task.taskId),
    completedTaskIds,
    objectiveProjectedStatus: "completed",
  };

  writeJson(path.join(stateRoot, "state.json"), state);
  writeJson(feedbackPath, feedback);
  writeJson(statusPath, status);
  process.stdout.write(`${JSON.stringify({ state, plannerBackend, plannerBackendPolicy, plannerBackendCapability, plannedTaskIds: status.plannedTaskIds, completedTaskIds })}\n`);
}

try {
  main();
} catch (error) {
  console.error(error && error.stack ? error.stack : String(error));
  process.exit(1);
}
