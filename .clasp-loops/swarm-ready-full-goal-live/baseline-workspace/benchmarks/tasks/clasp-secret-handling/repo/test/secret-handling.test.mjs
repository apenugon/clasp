import assert from "node:assert/strict";

import { runSecretHandlingDemo } from "../demo.mjs";

const compiledModulePath = process.argv[2];

if (!compiledModulePath) {
  throw new Error("usage: node test/secret-handling.test.mjs <compiled-module>");
}

const result = await runSecretHandlingDemo(compiledModulePath);

assert.deepStrictEqual(result, {
  messageCount: 3,
  promptHasSecretValue: false,
  agentTraceHasSecretValue: false,
  preparedMethod: "summarize_draft",
  preparedCallHasSecretValue: false,
  agentSecretNames: ["OPENAI_API_KEY"],
  toolSecretNames: ["SEARCH_API_TOKEN"],
  agentTracePolicy: "ReplyPolicy",
  agentTraceBoundary: "ReplyWorkerRole",
  agentResolvedName: "OPENAI_API_KEY",
  agentResolvedValue: "sk-live-openai",
  toolResolvedName: "SEARCH_API_TOKEN",
  toolResolvedValue: "tok-search-live",
  toolTracePolicy: "SearchPolicy",
  missingSecret: "Missing secret SEARCH_API_TOKEN for toolServer SearchTools under policy SearchPolicy",
  misusedSecret: "Undeclared secret OPENAI_API_KEY for tool summarizeDraft"
});

console.log(JSON.stringify(result));
