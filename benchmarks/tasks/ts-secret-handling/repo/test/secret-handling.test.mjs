import assert from "node:assert/strict";
import { runSecretHandlingDemo } from "../src/main.mjs";

const result = await runSecretHandlingDemo();

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
