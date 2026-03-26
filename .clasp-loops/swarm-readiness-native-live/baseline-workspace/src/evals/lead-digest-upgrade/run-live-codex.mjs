import {
  cpSync,
  existsSync,
  createWriteStream,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const evalRoot = dirname(fileURLToPath(import.meta.url));
const resultsRoot = join(evalRoot, "results");
const runId = new Date().toISOString().replaceAll(":", "-");
const model = process.env.CLASP_LIVE_MODEL ?? "gpt-5.4";
const reasoningEffort = process.env.CLASP_LIVE_REASONING_EFFORT ?? "high";
const keepWorkspaces = process.env.CLASP_KEEP_WORKSPACES === "true";

mkdirSync(resultsRoot, { recursive: true });

function listFiles(root) {
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

function parseCodexUsage(agentLogPath) {
  const lines = readFileSync(agentLogPath, "utf8")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line));
  const completion = [...lines].reverse().find((line) => line.type === "turn.completed");

  if (!completion?.usage) {
    throw new Error(`no completed Codex usage found in ${agentLogPath}`);
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

function readJsonLines(filePath) {
  if (!existsSync(filePath)) {
    return [];
  }

  return readFileSync(filePath, "utf8")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line));
}

function runCommand(command, args, options = {}) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd,
      env: options.env,
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

async function runCodex(promptText, workspace, agentLogPath) {
  return new Promise((resolvePromise, reject) => {
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

    const logStream = createWriteStream(agentLogPath, { encoding: "utf8" });
    child.stdout.pipe(logStream);
    child.stderr.pipe(process.stderr);
    child.stdin.end(promptText);

    child.on("error", reject);
    child.on("exit", (exitCode) => {
      logStream.end(() => {
        resolvePromise(exitCode ?? 1);
      });
    });
  });
}

function createWorkspace(modeId, taskText, semanticBrief) {
  const workspace = mkdtempSync(join(tmpdir(), `clasp-live-${modeId}-`));
  const startRoot = join(evalRoot, "start");
  const scriptsRoot = join(workspace, "scripts");

  mkdirSync(join(workspace, "Shared"), { recursive: true });
  mkdirSync(scriptsRoot, { recursive: true });
  cpSync(join(startRoot, "Main.clasp"), join(workspace, "Main.clasp"));
  cpSync(join(startRoot, "Shared", "Lead.clasp"), join(workspace, "Shared", "Lead.clasp"));

  writeFileSync(
    join(workspace, "AGENTS.md"),
    [
      "# Eval Workspace Instructions",
      "",
      "- Work only inside this workspace.",
      "- Do not inspect parent directories.",
      "- Prefer the smallest local edit set.",
      "- Run `bash scripts/verify.sh` before finishing.",
      "- Stop once the task is complete and verification passes."
    ].join("\n"),
    "utf8"
  );

  writeFileSync(join(workspace, "TASK.md"), taskText.trim() + "\n", "utf8");
  if (modeId === "clasp-aware") {
    writeFileSync(join(workspace, "CLASP_SEMANTIC_BRIEF.md"), semanticBrief.trim() + "\n", "utf8");
  }

  const verifyScript = `#!/usr/bin/env bash
set -euo pipefail

workspace_root="$(cd "$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
log_file="$workspace_root/benchmark-verify.jsonl"
started_ms="$(node -e 'process.stdout.write(String(Date.now()))')"
set +e
output="$(bash "${join(evalRoot, "validate.sh")}" "$workspace_root" 2>&1)"
status=$?
set -e
ended_ms="$(node -e 'process.stdout.write(String(Date.now()))')"
printf '%s\\n' "$output"
node -e 'const fs = require("fs"); fs.appendFileSync(process.argv[1], JSON.stringify({ startedAtMs: Number(process.argv[2]), endedAtMs: Number(process.argv[3]), exitCode: Number(process.argv[4]) }) + "\\n");' "$log_file" "$started_ms" "$ended_ms" "$status"
exit "$status"
`;
  writeFileSync(join(scriptsRoot, "verify.sh"), verifyScript, { encoding: "utf8", mode: 0o755 });

  return workspace;
}

function buildPrompts(taskText, semanticBrief) {
  const harnessInstructions = [
    "Benchmark harness instructions:",
    "- Work only inside the current workspace.",
    "- Do not inspect parent directories.",
    "- Prefer the smallest local edit set that satisfies the task.",
    "- Use the files in the workspace as the source of truth.",
    "- Run `bash scripts/verify.sh` before finishing.",
    "- Finish only after verification passes."
  ].join("\n");

  const rawPrompt = [harnessInstructions, "", taskText.trim()].join("\n");
  const claspPrompt = [harnessInstructions, "", taskText.trim(), "", "Compiler-derived semantic brief:", semanticBrief.trim()].join("\n");

  return {
    "raw-repo": rawPrompt,
    "clasp-aware": claspPrompt
  };
}

function summarizeVerifyLog(entries, startedAtMs) {
  const successful = entries.find((entry) => entry.exitCode === 0);
  const verifyAttempts = entries.length;
  return {
    verifyAttempts,
    repairLoops: successful ? Math.max(0, verifyAttempts - 1) : verifyAttempts,
    timeToGreenMs: successful ? successful.endedAtMs - startedAtMs : null,
    verifyEvents: entries
  };
}

function changedFilesAgainstStart(workspace) {
  const startRoot = join(evalRoot, "start");
  return listFiles(startRoot)
    .filter((file) => file.endsWith(".clasp"))
    .map((file) => relative(startRoot, file))
    .filter((relativePath) => {
      const startText = readFileSync(join(startRoot, relativePath), "utf8");
      const workspaceText = readFileSync(join(workspace, relativePath), "utf8");
      return startText !== workspaceText;
    });
}

async function loadCompareData() {
  const result = await runCommand("bash", [join(evalRoot, "compare.sh")], {
    cwd: evalRoot,
    env: process.env
  });
  if (result.exitCode !== 0) {
    throw new Error(`compare.sh failed: ${result.stderr || result.stdout}`);
  }
  return JSON.parse(result.stdout);
}

async function runMode(modeId, promptText, taskText, semanticBrief) {
  const workspace = createWorkspace(modeId, taskText, semanticBrief);
  const promptPath = join(resultsRoot, `${runId}--${modeId}.prompt.md`);
  const agentLogPath = join(resultsRoot, `${runId}--${modeId}.codex-run.jsonl`);
  writeFileSync(promptPath, promptText, "utf8");

  const startedAt = new Date();
  const startedAtMs = startedAt.getTime();
  const codexExitCode = await runCodex(promptText, workspace, agentLogPath);
  const finishedAt = new Date();

  const finalVerification = await runCommand("bash", [join(evalRoot, "validate.sh"), workspace], {
    cwd: evalRoot,
    env: process.env
  });
  const verifyLog = summarizeVerifyLog(readJsonLines(join(workspace, "benchmark-verify.jsonl")), startedAtMs);
  const usage = parseCodexUsage(agentLogPath);
  const changedFiles = changedFilesAgainstStart(workspace);

  const result = {
    eval: "lead-digest-upgrade",
    mode: modeId,
    harness: "codex",
    model,
    reasoningEffort,
    startedAt: startedAt.toISOString(),
    finishedAt: finishedAt.toISOString(),
    durationMs: finishedAt.getTime() - startedAtMs,
    promptFile: promptPath,
    promptBytes: Buffer.byteLength(promptText, "utf8"),
    codexExitCode,
    tokenUsage: {
      prompt: usage.prompt,
      completion: usage.completion,
      retry: usage.retry,
      debug: usage.debug,
      total: usage.total
    },
    harnessUsage: usage.harnessUsage,
    verification: {
      passed: finalVerification.exitCode === 0,
      exitCode: finalVerification.exitCode,
      output: finalVerification.stdout.trim()
    },
    verifyAttempts: verifyLog.verifyAttempts,
    repairLoops: verifyLog.repairLoops,
    timeToGreenMs: verifyLog.timeToGreenMs,
    changedFiles,
    changedFileCount: changedFiles.length,
    workspace: keepWorkspaces ? workspace : null
  };

  writeFileSync(join(resultsRoot, `${runId}--${modeId}.result.json`), JSON.stringify(result, null, 2) + "\n", "utf8");

  if (!keepWorkspaces) {
    rmSync(workspace, { recursive: true, force: true });
  }

  return result;
}

const compareData = await loadCompareData();
const taskText = compareData.taskText;
const semanticBrief = compareData.bundles.claspAwareText;
const prompts = buildPrompts(taskText, semanticBrief);

const rawRepo = await runMode("raw-repo", prompts["raw-repo"], taskText, semanticBrief);
const claspAware = await runMode("clasp-aware", prompts["clasp-aware"], taskText, semanticBrief);

const summary = {
  eval: "lead-digest-upgrade",
  harness: "codex",
  model,
  reasoningEffort,
  runId,
  rawRepo,
  claspAware,
  deltas: {
    durationMs: claspAware.durationMs - rawRepo.durationMs,
    totalTokens: claspAware.tokenUsage.total - rawRepo.tokenUsage.total,
    uncachedTokens:
      (claspAware.harnessUsage?.uncachedTotal ?? claspAware.tokenUsage.total) -
      (rawRepo.harnessUsage?.uncachedTotal ?? rawRepo.tokenUsage.total),
    verifyAttempts: claspAware.verifyAttempts - rawRepo.verifyAttempts,
    repairLoops: claspAware.repairLoops - rawRepo.repairLoops,
    timeToGreenMs:
      typeof claspAware.timeToGreenMs === "number" && typeof rawRepo.timeToGreenMs === "number"
        ? claspAware.timeToGreenMs - rawRepo.timeToGreenMs
        : null
  }
};

const summaryPath = join(resultsRoot, `${runId}--comparison.json`);
writeFileSync(summaryPath, JSON.stringify(summary, null, 2) + "\n", "utf8");

console.log(JSON.stringify({ summaryPath, summary }, null, 2));
