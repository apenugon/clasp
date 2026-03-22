import { pathToFileURL } from "node:url";

const compiledPath = process.argv[2];

if (!compiledPath) {
  throw new Error("usage: node examples/interop-ts/demo.mjs <compiled-module>");
}

const compiledModule = await import(pathToFileURL(compiledPath).href);
const packageBindings =
  typeof compiledModule.__claspPackageHostBindings === "function"
    ? compiledModule.__claspPackageHostBindings()
    : {};

globalThis.__claspRuntime = Object.freeze({
  ...(globalThis.__claspRuntime ?? {}),
  ...packageBindings,
});

console.log(
  JSON.stringify({
    packageKinds: (compiledModule.__claspPackageImports ?? [])
      .map((entry) => entry.kind)
      .sort(),
    upper: compiledModule.shout("hello ada"),
    formatted: compiledModule.describe({ company: "Acme Labs", budget: 7 }),
  })
);
