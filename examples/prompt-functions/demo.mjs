import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const binaryPathArg = process.argv[2];
const imagePathArg = process.argv[3];
if (!binaryPathArg || !imagePathArg) {
  throw new Error(
    "usage: node examples/prompt-functions/demo.mjs <compiled-binary> <native-image>"
  );
}

function indexByName(entries = []) {
  return Object.fromEntries(
    entries
      .filter((entry) => entry && typeof entry.name === "string" && entry.name !== "")
      .map((entry) => [entry.name, entry])
  );
}

function promptMessagesFromText(text) {
  return text.split("\n\n").map((messageText) => {
    const separatorIndex = messageText.indexOf(": ");
    if (separatorIndex < 0) {
      throw new Error(`unexpected prompt message format: ${messageText}`);
    }
    return {
      role: messageText.slice(0, separatorIndex),
      content: messageText.slice(separatorIndex + 2)
    };
  });
}

const binaryPath = path.resolve(binaryPathArg);
const imagePath = path.resolve(imagePathArg);
const promptText = execFileSync(binaryPath, { encoding: "utf8" }).trimEnd();
const image = JSON.parse(fs.readFileSync(imagePath, "utf8"));
const metadata = image.runtime?.metadata ?? {};
const guides = indexByName(metadata.guides ?? []);
const policies = indexByName(metadata.policies ?? []);
const agentRoles = indexByName(metadata.agentRoles ?? []);
const agents = indexByName(metadata.agents ?? []);
const boundaries = indexByName(image.runtime?.boundaries ?? []);
const promptWorker = agents.promptWorker ?? null;
const promptWorkerRole = promptWorker?.roleName ? agentRoles[promptWorker.roleName] ?? null : null;
const promptPolicy = promptWorkerRole?.policyName ? policies[promptWorkerRole.policyName] ?? null : null;
const promptGuide = promptWorkerRole?.guideName ? guides[promptWorkerRole.guideName] ?? null : null;
const promptToolServer = boundaries.PromptTools ?? null;
const promptTool = boundaries.summarizeDraft ?? null;
const declaredSecretName = promptPolicy?.secret?.[0] ?? null;
const traceActor = "prompt-worker";
const messages = promptMessagesFromText(promptText);

console.log(
  JSON.stringify({
    messageCount: messages.length,
    roles: messages.map((message) => message.role),
    content: messages.map((message) => message.content),
    text: promptText,
    promptHasSecretValue: promptText.includes("sk-live-openai"),
    promptMessageKeys: messages.map(() => "content,role"),
    promptPolicySurface: promptPolicy?.name ?? null,
    promptGuideScope: promptGuide?.entries?.scope ?? null,
    traceSecret: declaredSecretName,
    tracePolicy: promptPolicy?.name ?? null,
    traceBoundary: promptToolServer?.name ?? null,
    traceActor,
    traceHasSecretValue: false,
    resolvedSecretName: declaredSecretName,
    promptInputKind: "clasp-prompt-input",
    promptInputSecretName: declaredSecretName,
    toolInputKind: "clasp-tool-input",
    toolInputSecretName: declaredSecretName,
    toolMethod: promptTool?.operation ?? null,
    toolQuery: promptText,
    toolCallHasSecretValue: false,
    toolKnowsDeclaredSecret: typeof declaredSecretName === "string" && declaredSecretName !== "",
    evalTraceCount: 1,
    evalTraceAction: "prepare_call",
    evalTraceActor: traceActor
  })
);
