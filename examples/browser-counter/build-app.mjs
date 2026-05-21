#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { pathToFileURL } from "node:url";

const [, , compiledPathArg, outputPathArg] = process.argv;

if (!compiledPathArg || !outputPathArg) {
  throw new Error("usage: node examples/browser-counter/build-app.mjs <compiled-module.mjs> <output-index.html>");
}

const compiledPath = path.resolve(compiledPathArg);
const outputPath = path.resolve(outputPathArg);
const compiledModule = await import(pathToFileURL(compiledPath).href);
const html = typeof compiledModule.main === "function" ? compiledModule.main() : compiledModule.main;

if (typeof html !== "string" || !html.includes("<button id=\"increment\"")) {
  throw new Error("compiled Clasp module did not export the expected browser app HTML");
}

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, html);

const proof = proveCounterInteraction(html);

console.log(JSON.stringify({
  status: "ok",
  artifact: outputPath,
  title: extractTagText(html, "title"),
  initialCount: proof.initialCount,
  afterTwoClicks: proof.afterTwoClicks,
  hasModuleScript: proof.hasModuleScript,
  bytes: Buffer.byteLength(html, "utf8")
}));

function proveCounterInteraction(htmlText) {
  const scriptMatch = /<script\s+type="module">([\s\S]*?)<\/script>/i.exec(htmlText);
  if (!scriptMatch) {
    throw new Error("missing module script");
  }

  const countElement = createElement("count", extractElementText(htmlText, "strong", "count") ?? "");
  const incrementElement = createElement("increment", extractElementText(htmlText, "button", "increment") ?? "");
  const document = {
    getElementById(id) {
      if (id === "count") {
        return countElement;
      }
      if (id === "increment") {
        return incrementElement;
      }
      return null;
    }
  };

  vm.runInNewContext(scriptMatch[1], { document, String }, { timeout: 1000 });
  const initialCount = countElement.textContent;
  incrementElement.dispatch("click");
  incrementElement.dispatch("click");

  return {
    initialCount,
    afterTwoClicks: countElement.textContent,
    hasModuleScript: true
  };
}

function createElement(id, textContent) {
  const listeners = new Map();
  return {
    id,
    textContent,
    addEventListener(name, listener) {
      listeners.set(name, listener);
    },
    dispatch(name) {
      const listener = listeners.get(name);
      if (typeof listener !== "function") {
        throw new Error(`missing ${name} listener for ${id}`);
      }
      listener({ type: name, target: this });
    }
  };
}

function extractElementText(htmlText, tagName, id) {
  const pattern = new RegExp(`<${tagName}[^>]*id="${escapeRegExp(id)}"[^>]*>([\\s\\S]*?)<\\/${tagName}>`, "i");
  const match = pattern.exec(htmlText);
  return match ? decodeBasicHtml(match[1].trim()) : null;
}

function extractTagText(htmlText, tagName) {
  const pattern = new RegExp(`<${tagName}[^>]*>([\\s\\S]*?)<\\/${tagName}>`, "i");
  const match = pattern.exec(htmlText);
  return match ? decodeBasicHtml(match[1].trim()) : null;
}

function decodeBasicHtml(value) {
  return value
    .replace(/&quot;/g, "\"")
    .replace(/&gt;/g, ">")
    .replace(/&lt;/g, "<")
    .replace(/&amp;/g, "&");
}

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
