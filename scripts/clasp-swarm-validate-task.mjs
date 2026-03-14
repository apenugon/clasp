#!/usr/bin/env node

import fs from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const requiredSections = [
  "Goal",
  "Why",
  "Scope",
  "Likely Files",
  "Dependencies",
  "Acceptance",
  "Verification",
];

function fail(message) {
  throw new Error(message);
}

function normalizeText(value) {
  return value
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .join("\n")
    .trim();
}

function stripCodeTicks(value) {
  const trimmed = value.trim();
  const match = trimmed.match(/^`([^`]+)`$/);
  return match ? match[1] : trimmed;
}

function parseBullets(sectionName, raw, { allowNone = false } = {}) {
  const lines = raw
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);

  if (lines.length === 0) {
    fail(`section ${sectionName} must not be empty`);
  }

  if (allowNone && lines.length === 1 && lines[0] === "- None") {
    return [];
  }

  if (lines.some((line) => !line.startsWith("- "))) {
    fail(`section ${sectionName} must contain only markdown bullet items`);
  }

  return lines.map((line) => {
    const item = stripCodeTicks(line.slice(2));
    if (item.length === 0) {
      fail(`section ${sectionName} contains an empty bullet item`);
    }
    return item;
  });
}

function parseVerification(raw) {
  const trimmed = raw.trim();
  const match = trimmed.match(/^```([A-Za-z0-9_-]+)?\n([\s\S]*?)\n```$/);
  if (!match) {
    fail("section Verification must contain exactly one fenced code block");
  }

  const shell = (match[1] || "sh").trim();
  const command = match[2].trim();

  if (command.length === 0) {
    fail("section Verification must include a non-empty command");
  }

  return { shell, command };
}

function parseTaskManifest(taskPath) {
  const text = fs.readFileSync(taskPath, "utf8").replace(/\r\n/g, "\n");
  const basename = path.basename(taskPath, ".md");
  const taskKeyMatch = basename.match(/^([A-Z]{2,3}-[0-9]{3})(?:$|-)/);

  if (!taskKeyMatch) {
    fail(`task basename ${basename} must start with a task key like SW-001`);
  }

  const taskKey = taskKeyMatch[1];
  if (basename !== taskKey && !basename.startsWith(`${taskKey}-`)) {
    fail(`taskId ${basename} must equal ${taskKey} or start with ${taskKey}-`);
  }

  const lines = text.split("\n");
  const firstContentLine = lines.find((line) => line.trim().length > 0);
  if (!firstContentLine) {
    fail("task file is empty");
  }

  const headingMatch = firstContentLine.match(/^#\s+([A-Z]{2,3}-[0-9]{3})(?:\s+(.*\S))?\s*$/);
  if (!headingMatch) {
    fail("first markdown heading must be `# <task-key> <title>`");
  }
  if (headingMatch[1] !== taskKey) {
    fail(`heading task key ${headingMatch[1]} must match basename task key ${taskKey}`);
  }

  const title = (headingMatch[2] || "").trim();
  if (title.length === 0) {
    fail("manifest.title must be a non-empty string");
  }

  const sections = new Map();
  let currentSection = null;
  let currentLines = [];

  for (const line of lines.slice(lines.indexOf(firstContentLine) + 1)) {
    const sectionMatch = line.match(/^##\s+(.+?)\s*$/);
    if (sectionMatch) {
      if (currentSection) {
        if (sections.has(currentSection)) {
          fail(`duplicate section ${currentSection}`);
        }
        sections.set(currentSection, currentLines.join("\n").trim());
      }
      currentSection = sectionMatch[1];
      currentLines = [];
      continue;
    }

    if (currentSection) {
      currentLines.push(line);
    }
  }

  if (currentSection) {
    if (sections.has(currentSection)) {
      fail(`duplicate section ${currentSection}`);
    }
    sections.set(currentSection, currentLines.join("\n").trim());
  }

  for (const sectionName of requiredSections) {
    if (!sections.has(sectionName)) {
      fail(`missing required section ${sectionName}`);
    }
  }

  return {
    schemaVersion: 1,
    taskId: basename,
    taskKey,
    title,
    goal: normalizeText(sections.get("Goal")),
    why: normalizeText(sections.get("Why")),
    scope: parseBullets("Scope", sections.get("Scope")),
    likelyFiles: parseBullets("Likely Files", sections.get("Likely Files")),
    dependencies: parseBullets("Dependencies", sections.get("Dependencies"), { allowNone: true }),
    acceptance: parseBullets("Acceptance", sections.get("Acceptance")),
    verification: parseVerification(sections.get("Verification")),
  };
}

function validateSchema(schema, value, valuePath = "manifest") {
  const errors = [];

  const pushError = (message) => {
    errors.push(`${valuePath}${message}`);
  };

  if (schema.type) {
    const actualType = Array.isArray(value) ? "array" : value === null ? "null" : typeof value;
    if (schema.type === "integer") {
      if (!Number.isInteger(value)) {
        pushError(" must be an integer");
        return errors;
      }
    } else if (actualType !== schema.type) {
      pushError(` must be of type ${schema.type}`);
      return errors;
    }
  }

  if (Object.prototype.hasOwnProperty.call(schema, "const") && value !== schema.const) {
    pushError(` must equal ${JSON.stringify(schema.const)}`);
  }

  if (schema.enum && !schema.enum.includes(value)) {
    pushError(` must be one of ${schema.enum.join(", ")}`);
  }

  if (typeof value === "string") {
    if (schema.minLength && value.length < schema.minLength) {
      pushError(` must have length >= ${schema.minLength}`);
    }
    if (schema.pattern && !(new RegExp(schema.pattern).test(value))) {
      pushError(` must match ${schema.pattern}`);
    }
  }

  if (Array.isArray(value)) {
    if (schema.minItems && value.length < schema.minItems) {
      pushError(` must contain at least ${schema.minItems} item(s)`);
    }
    if (schema.items) {
      value.forEach((item, index) => {
        errors.push(...validateSchema(schema.items, item, `${valuePath}[${index}]`));
      });
    }
  }

  if (value && typeof value === "object" && !Array.isArray(value)) {
    const keys = Object.keys(value);
    const propertySchemas = schema.properties || {};

    if (schema.required) {
      for (const key of schema.required) {
        if (!Object.prototype.hasOwnProperty.call(value, key)) {
          errors.push(`${valuePath}.${key} is required`);
        }
      }
    }

    if (schema.additionalProperties === false) {
      for (const key of keys) {
        if (!Object.prototype.hasOwnProperty.call(propertySchemas, key)) {
          errors.push(`${valuePath}.${key} is not allowed`);
        }
      }
    }

    for (const [key, propertySchema] of Object.entries(propertySchemas)) {
      if (Object.prototype.hasOwnProperty.call(value, key)) {
        errors.push(...validateSchema(propertySchema, value[key], `${valuePath}.${key}`));
      }
    }
  }

  return errors;
}

function printField(value) {
  if (Array.isArray(value)) {
    process.stdout.write(value.join("\n"));
    if (value.length > 0) {
      process.stdout.write("\n");
    }
    return;
  }

  if (value && typeof value === "object") {
    process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
    return;
  }

  process.stdout.write(`${String(value)}\n`);
}

function main() {
  const args = process.argv.slice(2);
  let printManifest = false;
  let printFieldName = "";
  const taskPaths = [];

  while (args.length > 0) {
    const arg = args.shift();
    if (arg === "--print-manifest") {
      printManifest = true;
      continue;
    }
    if (arg === "--print-field") {
      printFieldName = args.shift() || "";
      if (printFieldName.length === 0) {
        fail("missing field name after --print-field");
      }
      continue;
    }
    taskPaths.push(arg);
  }

  if (taskPaths.length === 0) {
    fail("expected at least one task path");
  }
  if ((printManifest || printFieldName) && taskPaths.length !== 1) {
    fail("--print-manifest and --print-field require exactly one task path");
  }

  const scriptDir = path.dirname(fileURLToPath(import.meta.url));
  const projectRoot = path.resolve(scriptDir, "..");
  const schemaPath = path.join(projectRoot, "agents", "swarm", "task.schema.json");
  const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));

  const manifests = taskPaths.map((taskPath) => {
    let manifest;
    try {
      manifest = parseTaskManifest(taskPath);
    } catch (error) {
      fail(`${taskPath}: ${error.message}`);
    }
    const errors = validateSchema(schema, manifest);
    if (errors.length > 0) {
      fail(`${taskPath}\n- ${errors.join("\n- ")}`);
    }
    return manifest;
  });

  if (printManifest) {
    process.stdout.write(`${JSON.stringify(manifests[0], null, 2)}\n`);
    return;
  }

  if (printFieldName) {
    const manifest = manifests[0];
    if (!Object.prototype.hasOwnProperty.call(manifest, printFieldName)) {
      fail(`manifest.${printFieldName} does not exist`);
    }
    printField(manifest[printFieldName]);
  }
}

try {
  main();
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exit(1);
}
