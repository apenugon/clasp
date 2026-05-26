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

function plannerPrompt(maxTaskLoops, goalText, stateRoot, workspaceRoot) {
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

  ensureDir(stateRoot);
  ensureDir(workspaceRoot);

  const plannerReportPath = path.join(stateRoot, "planner-1.json");
  const plannerPromptPath = path.join(stateRoot, "planner-1.prompt.txt");
  const plannerSchemaPath = readJsonEnv(
    "CLASP_MANAGER_PLANNER_SCHEMA_JSON",
    path.join(managerProjectRoot, "agents/schemas/planner-report.schema.json"),
  );
  const plannerStdoutPath = path.join(stateRoot, "planner-1.stdout.log");
  const plannerStderrPath = path.join(stateRoot, "planner-1.stderr.log");
  const prompt = plannerPrompt(maxTaskLoops, goalText, stateRoot, workspaceRoot);
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
    plannedTaskIds: tasks.map((task) => task.taskId),
    completedTaskIds,
    objectiveProjectedStatus: "completed",
  };

  writeJson(path.join(stateRoot, "state.json"), state);
  writeJson(feedbackPath, feedback);
  writeJson(statusPath, status);
  process.stdout.write(`${JSON.stringify({ state, plannedTaskIds: status.plannedTaskIds, completedTaskIds })}\n`);
}

try {
  main();
} catch (error) {
  console.error(error && error.stack ? error.stack : String(error));
  process.exit(1);
}
