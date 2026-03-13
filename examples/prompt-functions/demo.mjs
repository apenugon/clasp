import { pathToFileURL } from "node:url";

const compiledPath = process.argv[2];

if (!compiledPath) {
  throw new Error("usage: node examples/prompt-functions/demo.mjs <compiled-module>");
}

const compiledModule = await import(pathToFileURL(compiledPath).href);

console.log(
  JSON.stringify({
    messageCount: compiledModule.replyPromptValue.messages.length,
    roles: compiledModule.replyPromptValue.messages.map((message) => message.role),
    content: compiledModule.replyPromptValue.messages.map((message) => message.content),
    text: compiledModule.replyPromptText
  })
);
