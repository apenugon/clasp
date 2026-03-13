#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

const projectRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const planPath = path.join(projectRoot, "docs", "clasp-project-plan.md");
const swarmRoot = path.join(projectRoot, "agents", "swarm");
const fullWaveDir = path.join(swarmRoot, "full");

const laneConfig = {
  SW: {
    lane: "01-swarm-infra",
    label: "Swarm Infrastructure",
    why: "The swarm itself needs to be reliable before it can safely drive the rest of the project.",
    likelyFiles: [
      "agents/swarm/",
      "scripts/clasp-swarm-*.sh",
      "scripts/test-swarm-control.sh",
      "docs/clasp-project-plan.md",
    ],
  },
  LG: {
    lane: "02-core-language",
    label: "Core Language Surface",
    why: "The core language still needs enough control flow and ergonomics to support nontrivial application logic.",
    likelyFiles: [
      "src/Clasp/Syntax.hs",
      "src/Clasp/Parser.hs",
      "src/Clasp/Checker.hs",
      "src/Clasp/Lower.hs",
      "src/Clasp/Emit/JavaScript.hs",
      "test/Main.hs",
      "docs/clasp-spec-v0.md",
      "examples/",
    ],
  },
  TY: {
    lane: "03-type-system",
    label: "Type System And Diagnostics",
    why: "Clasp needs stronger typing and more useful diagnostics than mainstream baseline stacks if the language thesis is going to hold up.",
    likelyFiles: [
      "src/Clasp/Core.hs",
      "src/Clasp/Checker.hs",
      "src/Clasp/Diagnostic.hs",
      "src/Clasp/Lower.hs",
      "test/Main.hs",
      "docs/clasp-spec-v0.md",
    ],
  },
  SC: {
    lane: "04-schemas",
    label: "Schemas And Trust Boundaries",
    why: "Generated trust-boundary handling is one of the main reasons Clasp should outperform baseline stacks in agent-driven work.",
    likelyFiles: [
      "src/Clasp/Checker.hs",
      "src/Clasp/Lower.hs",
      "src/Clasp/Emit/JavaScript.hs",
      "runtime/",
      "test/Main.hs",
      "docs/clasp-spec-v0.md",
      "examples/",
    ],
  },
  FS: {
    lane: "05-full-stack",
    label: "Full-Stack Runtime And App Layer",
    why: "Clasp needs one shared app surface that spans backend, frontend, workers, and eventually mobile.",
    likelyFiles: [
      "src/Clasp/Emit/JavaScript.hs",
      "runtime/bun/",
      "examples/",
      "benchmarks/",
      "test/Main.hs",
      "docs/clasp-spec-v0.md",
    ],
  },
  CP: {
    lane: "06-control-plane",
    label: "Control Plane",
    why: "The agent platform only becomes real when permissions, commands, hooks, agents, and policies are first-class declarations.",
    likelyFiles: [
      "src/Clasp/",
      "runtime/",
      "scripts/",
      "docs/",
      "agents/",
      "test/Main.hs",
    ],
  },
  WF: {
    lane: "07-workflows",
    label: "Durable Workflows And Hot Swap",
    why: "Long-running agent systems need durable state, replay, and supervised self-update before Clasp can claim real autonomy.",
    likelyFiles: [
      "src/Clasp/",
      "runtime/",
      "examples/",
      "test/Main.hs",
      "docs/",
    ],
  },
  AI: {
    lane: "08-ai-platform",
    label: "AI-Native Platform",
    why: "Typed model boundaries, tools, evals, and traces are central to the language thesis rather than an optional library layer.",
    likelyFiles: [
      "src/Clasp/",
      "runtime/",
      "examples/",
      "benchmarks/",
      "test/Main.hs",
      "docs/",
    ],
  },
  EO: {
    lane: "09-external-objectives",
    label: "External-Objective Adaptation",
    why: "Clasp’s long-term differentiator is the ability to relate runtime and business signals back to typed code and policy changes.",
    likelyFiles: [
      "src/Clasp/",
      "runtime/",
      "examples/",
      "benchmarks/",
      "test/Main.hs",
      "docs/",
    ],
  },
  BM: {
    lane: "10-benchmarks",
    label: "Benchmark Program",
    why: "The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes.",
    likelyFiles: [
      "benchmarks/",
      "examples/",
      "docs/",
      "scripts/",
    ],
  },
  SA: {
    lane: "11-saas-dogfood",
    label: "SaaS Dogfooding",
    why: "The real test is whether agents can build and evolve a moderate product in Clasp rather than only patch compiler features.",
    likelyFiles: [
      "examples/",
      "runtime/",
      "benchmarks/",
      "docs/",
      "test/",
    ],
  },
  SH: {
    lane: "12-self-hosting",
    label: "Self-Hosting",
    why: "Clasp should eventually be able to carry its own compiler once the language and runtime are mature enough.",
    likelyFiles: [
      "src/",
      "examples/",
      "docs/",
      "test/",
      "benchmarks/",
    ],
  },
  NB: {
    lane: "13-native-backend",
    label: "Native Backend And Bytecode",
    why: "Clasp needs a path beyond JavaScript for backend and compiler workloads once the hosted path is proven.",
    likelyFiles: [
      "src/",
      "runtime/",
      "docs/",
      "test/",
      "benchmarks/",
    ],
  },
  DB: {
    lane: "14-sqlite",
    label: "SQLite Storage",
    why: "SQLite is the first persistence milestone after the app and language surfaces are already credible.",
    likelyFiles: [
      "src/",
      "runtime/",
      "examples/",
      "benchmarks/",
      "docs/",
      "test/",
    ],
  },
};

const startDependencies = {
  SW: [],
  LG: [],
  TY: ["LG-019"],
  SC: ["TY-010"],
  FS: ["SC-013"],
  CP: ["FS-005"],
  WF: ["CP-012"],
  AI: ["WF-010"],
  EO: ["AI-011"],
  BM: [],
  SA: ["AI-011", "FS-010"],
  SH: ["SA-010"],
  NB: ["SH-010"],
  DB: ["NB-008"],
};

const specialDependencies = {
  "BM-001": ["FS-005"],
  "BM-002": ["BM-001"],
  "BM-003": ["AI-011"],
  "BM-004": ["FS-003"],
  "BM-005": ["SC-013"],
  "BM-006": ["CP-009"],
  "BM-007": ["WF-010"],
  "BM-008": ["WF-010"],
  "BM-009": ["LG-019"],
  "BM-010": ["EO-007"],
  "BM-011": ["BM-010"],
  "BM-012": ["SA-010"],
  "BM-013": ["SH-010"],
  "BM-014": ["NB-008"],
  "BM-015": ["DB-006"],
  "BM-022": ["FS-017", "FS-019", "FS-015", "CP-013"],
  "BM-023": ["BM-022", "CP-013", "FS-015", "TY-015"],
  "BM-024": ["BM-023", "FS-022"],
  "BM-037": ["TY-024", "SC-023"],
  "BM-038": ["WF-019"],
  "BM-039": ["TY-025", "TY-026"],
  "BM-040": ["TY-028", "FS-025"],
  "FS-017": ["FS-015"],
  "FS-025": ["TY-027", "TY-028", "FS-020", "FS-021", "FS-022"],
  "NB-010": ["NB-002"],
  "NB-011": ["NB-010"],
  "NB-003": ["NB-011"],
  "SC-023": ["TY-024"],
  "TY-027": ["TY-009"],
  "TY-028": ["TY-027"],
};

const specialScopeBullets = {
  "DB-007": [
    "Require storage-facing schemas, table declarations, and generated constraints to use shared semantic/domain types instead of bare primitives",
    "Ensure generated storage metadata preserves the same semantic type identities used at route, schema, and application boundaries",
  ],
  "DB-008": [
    "Keep transaction inputs, mutation outputs, and row-mapping surfaces in shared semantic types rather than exposing raw primitive rows",
    "Reject transaction or mutation APIs that reintroduce bare primitive storage-facing types where shared semantic types already exist",
  ],
  "DB-010": [
    "Require protected row and field access to preserve policy proofs and shared semantic types end to end instead of degrading to primitive storage values",
    "Ensure policy-aware query and mutation surfaces do not fall back to bare primitives on storage-facing declarations, row contracts, or protected projections",
  ],
};

const specialAcceptanceBullets = {
  "DB-007": [
    "Storage-facing declarations reject bare primitives where shared semantic/domain types are required",
  ],
  "DB-008": [
    "Transaction and mutation surfaces preserve semantic storage types instead of raw primitive rows",
  ],
  "DB-010": [
    "Policy-aware storage access preserves proof-gated semantic types without primitive fallback at protected row or field boundaries",
  ],
};

const trackNames = {
  SW: "Swarm Infrastructure",
  LG: "Core Language Surface",
  TY: "Type System And Diagnostics",
  SC: "Schemas And Trust Boundaries",
  FS: "Full-Stack Runtime And App Layer",
  CP: "Control Plane Declarations",
  WF: "Durable Workflows And Hot Swap",
  AI: "AI-Native Platform",
  EO: "External-Objective Adaptation",
  BM: "Benchmark Program",
  SA: "SaaS Dogfooding",
  SH: "Self-Hosting",
  NB: "Native Backend And Bytecode",
  DB: "SQLite Storage",
};

const taskPattern = /^- `([A-Z]{2}-[0-9]{3})` (.+?)\.$/;
const planText = fs.readFileSync(planPath, "utf8");
const lines = planText.split(/\r?\n/);
const tasks = [];
let currentTrack = "";

for (const line of lines) {
  const trackMatch = line.match(/^### Track \d+: (.+)$/);
  if (trackMatch) {
    currentTrack = trackMatch[1];
    continue;
  }

  const taskMatch = line.match(taskPattern);
  if (!taskMatch) {
    continue;
  }

  const [, id, description] = taskMatch;
  if (tasks.some((task) => task.id === id)) {
    continue;
  }

  tasks.push({
    id,
    prefix: id.split("-")[0],
    description,
    track: currentTrack,
  });
}

const previousByPrefix = new Map();

const slugify = (value) =>
  value
    .toLowerCase()
    .replace(/`/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");

const titleCase = (value) =>
  value
    .replace(/`([^`]+)`/g, "$1")
    .split(/(\s+|\/|-)/)
    .map((segment) => {
      if (/^\s+$/.test(segment) || segment === "/" || segment === "-") {
        return segment;
      }
      if (/^[A-Z0-9]+$/.test(segment)) {
        return segment;
      }
      return segment.charAt(0).toUpperCase() + segment.slice(1);
    })
    .join("");

const taskRecords = tasks.map((task) => {
  const config = laneConfig[task.prefix];
  if (!config) {
    throw new Error(`No lane config for ${task.id}`);
  }

  let dependencies;
  if (specialDependencies[task.id]) {
    dependencies = specialDependencies[task.id];
  } else {
    const previous = previousByPrefix.get(task.prefix);
    dependencies = previous ? [previous] : [...(startDependencies[task.prefix] || [])];
  }

  previousByPrefix.set(task.prefix, task.id);

  return {
    ...task,
    ...config,
    dependencies,
    slug: slugify(task.description),
  };
});

fs.rmSync(fullWaveDir, { recursive: true, force: true });
fs.mkdirSync(fullWaveDir, { recursive: true });

const laneOrder = [...new Set(Object.values(laneConfig).map((config) => config.lane))].sort();
for (const lane of laneOrder) {
  fs.mkdirSync(path.join(fullWaveDir, lane), { recursive: true });
}

const readme = [];
readme.push("# Full Backlog", "");
readme.push("This wave materializes the full Clasp project backlog from `docs/clasp-project-plan.md`.", "");
readme.push("It is the intended default swarm target once the current `wave1` work is merged forward.", "");
readme.push("The swarm waits for every dependency listed in a task file before starting that task.", "");
readme.push("Lanes in this wave:", "");
for (const lane of laneOrder) {
  const entry = Object.values(laneConfig).find((config) => config.lane === lane);
  const count = taskRecords.filter((task) => task.lane === lane).length;
  readme.push(`- \`${lane}\`: ${entry.label} (${count} tasks)`);
}
readme.push("", `Total tasks: ${taskRecords.length}`, "");
readme.push("Regenerate with:", "", "```sh", "node scripts/materialize-full-backlog.mjs", "```", "");
fs.writeFileSync(path.join(fullWaveDir, "README.md"), `${readme.join("\n")}\n`, "utf8");

for (const task of taskRecords) {
  const content = [];
  content.push(`# ${task.id} ${titleCase(task.description)}`, "");
  content.push("## Goal", "");
  content.push(task.description, "");
  content.push("## Why", "");
  content.push(`${task.why} This task belongs to the ${trackNames[task.prefix] ?? task.track} track.`, "");
  content.push("## Scope", "");
  content.push(`- Implement \`${task.id}\` as one narrow slice of work: ${task.description}`);
  content.push("- Add or update regression coverage for the new behavior");
  content.push("- If the task changes runtime behavior, trust boundaries, workflows, interop, or app/user-facing execution surfaces, add or update at least one scenario-level or end-to-end verification path");
  content.push("- Update docs or examples only where the new surface changes visible behavior");
  content.push("- Avoid unrelated refactors or broad rewrites");
  for (const bullet of specialScopeBullets[task.id] || []) {
    content.push(`- ${bullet}`);
  }
  content.push("", "## Likely Files", "");
  for (const file of task.likelyFiles) {
    content.push(`- \`${file}\``);
  }
  content.push("", "## Dependencies", "");
  if (task.dependencies.length === 0) {
    content.push("- None");
  } else {
    for (const dependency of task.dependencies) {
      content.push(`- \`${dependency}\``);
    }
  }
  content.push("", "## Acceptance", "");
  content.push(`- \`${task.id}\` is implemented without breaking previously integrated tasks`);
  content.push("- Tests or regressions cover the new behavior");
  content.push("- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression");
  for (const bullet of specialAcceptanceBullets[task.id] || []) {
    content.push(`- ${bullet}`);
  }
  content.push("- `bash scripts/verify-all.sh` passes");
  content.push("", "## Verification", "", "```sh", "bash scripts/verify-all.sh", "```", "");

  const outputPath = path.join(fullWaveDir, task.lane, `${task.id}-${task.slug}.md`);
  fs.writeFileSync(outputPath, content.join("\n"), "utf8");
}

console.log(`Generated ${taskRecords.length} tasks under ${path.relative(projectRoot, fullWaveDir)}`);
