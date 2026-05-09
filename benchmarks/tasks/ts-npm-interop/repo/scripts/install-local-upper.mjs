import { mkdirSync, writeFileSync } from "node:fs";

mkdirSync("node_modules/local-upper", { recursive: true });

writeFileSync(
  "node_modules/local-upper/index.mjs",
  "export function upperCase(value) {\n  return value.toUpperCase();\n}\n",
  "utf8"
);

writeFileSync(
  "node_modules/local-upper/package.json",
  JSON.stringify({
    name: "local-upper",
    type: "module",
    exports: "./index.mjs"
  }, null, 2) + "\n",
  "utf8"
);
