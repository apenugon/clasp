#!/usr/bin/env node

import { writeFileSync } from "node:fs";

const query = process.argv[2] ?? "";
const logPath = process.argv[3] ?? "";

const lowered = query.toLowerCase();
const results = lowered.includes("force majeure")
  ? [
      {
        resultId: "web-delaware-force-majeure",
        title: "Delaware Force Majeure Update",
        url: "https://example.test/delaware-force-majeure",
        summary: "Recent Delaware guidance emphasizes reading the contract text before asserting force majeure."
      },
      {
        resultId: "web-contract-remedies",
        title: "Commercial Contract Remedies Overview",
        url: "https://example.test/contract-remedies",
        summary: "Remedy availability turns on notice, cure periods, and explicit limitation clauses."
      }
    ]
  : [
      {
        resultId: "web-general-contracts",
        title: "Contract Research Digest",
        url: "https://example.test/contracts",
        summary: "Supplemental contract research should be cited separately from internal document retrieval."
      }
    ];

if (logPath !== "") {
  writeFileSync(logPath, JSON.stringify({ query, resultCount: results.length }, null, 2));
}

process.stdout.write(JSON.stringify({ query, results }));
