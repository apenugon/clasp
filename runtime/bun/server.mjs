export function installRuntime(bindings) {
  const previous = globalThis.__claspRuntime ?? {};
  globalThis.__claspRuntime = {
    ...previous,
    ...bindings
  };
}

export function bindingContractFor(compiledModule) {
  const contract = compiledModule?.__claspBindings;

  if (
    contract &&
    contract.kind === "clasp-generated-bindings" &&
    contract.version === 1
  ) {
    return {
      ...contract,
      nativeInterop:
        contract.nativeInterop ??
        compiledModule?.__claspNativeInterop ??
        defaultNativeInterop(contract.hostBindings ?? compiledModule?.__claspHostBindings ?? [])
    };
  }

  return {
    kind: "clasp-generated-bindings",
    version: 1,
    hostBindings: compiledModule?.__claspHostBindings ?? [],
    nativeInterop:
      compiledModule?.__claspNativeInterop ??
      defaultNativeInterop(compiledModule?.__claspHostBindings ?? []),
    packageImports: compiledModule?.__claspPackageImports ?? [],
    routes: compiledModule?.__claspRoutes ?? [],
    routeClients: compiledModule?.__claspRouteClients ?? [],
    schemas: compiledModule?.__claspSchemas ?? {},
    platformBridges:
      compiledModule?.__claspPlatformBridges ?? defaultPlatformBridges(),
    seededFixtures: compiledModule?.__claspSeededFixtures ?? [],
    staticAssetStrategy:
      compiledModule?.__claspStaticAssetStrategy ?? {
        assetBasePath: "/assets",
        generatedAssetBasePath: "/assets/clasp"
      },
    staticAssets: compiledModule?.__claspStaticAssets ?? [],
    styleBundles: compiledModule?.__claspStyleBundles ?? [],
    headStrategy:
      compiledModule?.__claspHeadStrategy ?? {
        charset: "utf-8",
        viewport: "width=device-width, initial-scale=1"
      },
    uiGraph: compiledModule?.__claspUiGraph ?? [],
    navigationGraph: compiledModule?.__claspNavigationGraph ?? [],
    actionGraph: compiledModule?.__claspActionGraph ?? []
  };
}

function defaultNativeInterop(hostBindings) {
  return Object.freeze({
    version: 1,
    abi: "clasp-native-v1",
    supportedTargets: Object.freeze(["bun", "worker", "react-native", "expo"]),
    bindings: Object.freeze((hostBindings ?? []).map(defaultNativeInteropBinding))
  });
}

function defaultNativeInteropBinding(binding) {
  const bindingKey = nativeInteropKey(binding?.name ?? binding?.runtimeName ?? "binding");
  const crateName = `clasp_${bindingKey}`;
  const nativeRoot = `native/${bindingKey}`;
  const cargoManifest = `${nativeRoot}/Cargo.toml`;

  return Object.freeze({
    name: binding?.name ?? bindingKey,
    runtimeName: binding?.runtimeName ?? binding?.name ?? bindingKey,
    capability: Object.freeze({
      id: `capability:foreign:${binding?.name ?? bindingKey}`,
      kind: "foreign-function",
      runtimeName: binding?.runtimeName ?? binding?.name ?? bindingKey
    }),
    generatedBinding: Object.freeze({
      module: `generated/native/${bindingKey}.mjs`,
      export: binding?.name ?? bindingKey
    }),
    rustCrate: Object.freeze({
      crateName,
      manifestPath: cargoManifest,
      libName: crateName,
      entrySymbol: binding?.runtimeName ?? binding?.name ?? bindingKey
    }),
    nativeLibrary: Object.freeze({
      baseName: crateName,
      headerPath: `${nativeRoot}/include/${crateName}.h`,
      entrySymbol: binding?.runtimeName ?? binding?.name ?? bindingKey
    }),
    targets: Object.freeze({
      bun: Object.freeze({
        runtime: "bun",
        loader: "bun:ffi",
        crateType: "cdylib",
        manifestPath: cargoManifest
      }),
      worker: Object.freeze({
        runtime: "bun",
        loader: "bun:ffi",
        crateType: "cdylib",
        manifestPath: cargoManifest
      }),
      reactNative: Object.freeze({
        runtime: "react-native",
        loader: "turbo-module",
        crateType: "staticlib",
        manifestPath: cargoManifest
      }),
      expo: Object.freeze({
        runtime: "expo",
        loader: "expo-module",
        crateType: "staticlib",
        manifestPath: cargoManifest
      })
    })
  });
}

function nativeInteropKey(name) {
  const key = String(name)
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");

  return key === "" ? "binding" : key;
}

export function nativeInteropContractFor(compiledModule) {
  return bindingContractFor(compiledModule).nativeInterop;
}

export function resolveNativeInteropPlan(compiledModule, options = {}) {
  const contract = nativeInteropContractFor(compiledModule);
  const target = normalizeNativeInteropTarget(options.target);
  const targetTriple =
    typeof options.targetTriple === "string" && options.targetTriple !== ""
      ? options.targetTriple
      : null;
  const release = options.release !== false;
  const bindingOverrides =
    options.bindings && typeof options.bindings === "object" ? options.bindings : {};
  const bindings = (contract.bindings ?? []).map((binding) => {
    const targetConfig = binding.targets?.[target.key];

    if (!targetConfig) {
      throw new Error(`Native interop target ${target.name} is not declared for ${binding.name}.`);
    }

    const override =
      bindingOverrides[binding.name] ??
      bindingOverrides[binding.runtimeName] ??
      {};
    const manifestPath =
      override.manifestPath ??
      override.cargoManifest ??
      targetConfig.manifestPath ??
      binding.rustCrate?.manifestPath ??
      null;
    const crateName = override.crateName ?? binding.rustCrate?.crateName ?? binding.name;
    const libName =
      override.libName ??
      override.baseName ??
      binding.nativeLibrary?.baseName ??
      binding.rustCrate?.libName ??
      crateName;
    const cargoCommand = [
      "cargo",
      "build",
      "--manifest-path",
      manifestPath
    ];

    if (release) {
      cargoCommand.push("--release");
    }

    if (targetTriple) {
      cargoCommand.push("--target", targetTriple);
    }

    return Object.freeze({
      name: binding.name,
      runtimeName: binding.runtimeName,
      capabilityId: binding.capability?.id ?? null,
      crateName,
      manifestPath,
      libName,
      generatedBinding: binding.generatedBinding ?? null,
      loader: targetConfig.loader,
      crateType: targetConfig.crateType,
      runtime: targetConfig.runtime,
      target: target.name,
      targetTriple,
      artifactFileName: nativeArtifactFileName(targetConfig.crateType, libName, targetTriple),
      capabilities: normalizeCapabilities(binding, override.capabilities),
      cargo: Object.freeze({
        command: cargoCommand,
        release,
        targetTriple
      })
    });
  });

  return Object.freeze({
    kind: "clasp-native-build-plan",
    version: 1,
    abi: contract.abi ?? "clasp-native-v1",
    target: target.name,
    targetTriple,
    release,
    bindings
  });
}

function normalizeNativeInteropTarget(target) {
  switch (target) {
    case undefined:
    case null:
    case "bun":
    case "server":
      return { key: "bun", name: "bun" };
    case "worker":
    case "bun-worker":
      return { key: "worker", name: "worker" };
    case "react-native":
    case "reactNative":
      return { key: "reactNative", name: "react-native" };
    case "expo":
      return { key: "expo", name: "expo" };
    default:
      throw new Error(`Unsupported Clasp native interop target: ${String(target)}`);
  }
}

function nativeArtifactFileName(crateType, libName, targetTriple) {
  if (crateType === "staticlib") {
    return `lib${libName}.a`;
  }

  const triple = targetTriple ?? "";

  if (triple.includes("windows")) {
    return `${libName}.dll`;
  }

  if (triple.includes("apple") || triple.includes("darwin")) {
    return `lib${libName}.dylib`;
  }

  return `lib${libName}.so`;
}

function normalizeCapabilities(binding, capabilitiesOverride) {
  if (Array.isArray(capabilitiesOverride) && capabilitiesOverride.length > 0) {
    return capabilitiesOverride.slice();
  }

  return binding.capability?.id ? [binding.capability.id] : [];
}

function defaultPlatformBridges() {
  return Object.freeze({
    react: Object.freeze({
      module: "runtime/bun/react.mjs",
      entry: "createReactInterop"
    }),
    reactNative: Object.freeze({
      module: "runtime/bun/react.mjs",
      entry: "createReactNativeBridge"
    }),
    expo: Object.freeze({
      module: "runtime/bun/react.mjs",
      entry: "createExpoBridge"
    })
  });
}

export function installCompiledModule(compiledModule, implementations = {}) {
  if (!compiledModule || typeof compiledModule.__claspAdaptHostBindings !== "function") {
    throw new Error("installCompiledModule requires a generated Clasp module.");
  }

  const packageBindings =
    typeof compiledModule.__claspPackageHostBindings === "function"
      ? compiledModule.__claspPackageHostBindings()
      : {};
  const runtimeBindings = {
    ...packageBindings,
    ...compiledModule.__claspAdaptHostBindings(implementations)
  };
  installRuntime(runtimeBindings);
  return runtimeBindings;
}

export async function requestPayloadJson(route, request) {
  const url = new URL(request.url);

  if (request.method === "GET") {
    return JSON.stringify(
      coerceRequestObject(readSearchParams(url.searchParams), route.requestSchema)
    );
  }

  const contentType = request.headers.get("content-type") ?? "";

  if (contentType.includes("application/json")) {
    const rawBody = (await request.text()).trim();
    return rawBody === "" ? "{}" : rawBody;
  }

  if (contentType.includes("application/x-www-form-urlencoded")) {
    const rawBody = await request.text();
    return JSON.stringify(
      coerceRequestObject(
        readSearchParams(new URLSearchParams(rawBody)),
        route.requestSchema
      )
    );
  }

  const rawBody = (await request.text()).trim();
  return rawBody === "" ? "{}" : rawBody;
}

export function serveCompiledModule(compiledModule, options = {}) {
  if (typeof Bun === "undefined" || typeof Bun.serve !== "function") {
    throw new Error("serveCompiledModule requires Bun.");
  }

  const contract = bindingContractFor(compiledModule);
  const routes = contract.routes;
  const port = options.port ?? 3001;

  return Bun.serve({
    port,
    async fetch(request) {
      const url = new URL(request.url);
      const assetResponse = await responseForAssetRequest(compiledModule, url.pathname, options);

      if (assetResponse) {
        return assetResponse;
      }

      const route = routes.find(
        (candidate) =>
          candidate.method === request.method && candidate.path === url.pathname
      );

      if (!route) {
        return jsonResponse(404, { error: "not_found", path: url.pathname });
      }

      let payload;
      try {
        payload = route.decodeRequest(await requestPayloadJson(route, request));
      } catch (error) {
        return errorResponse(route, 400, "invalid_request", error);
      }

      let result;
      try {
        result = await route.handler(payload);
      } catch (error) {
        return errorResponse(route, 502, "handler_failed", error);
      }

      try {
        return responseForRouteResult(route, result);
      } catch (error) {
        return errorResponse(route, 500, "invalid_response", error);
      }
    }
  });
}

export async function responseForAssetRequest(compiledModule, pathname, options = {}) {
  const contract = bindingContractFor(compiledModule);
  const generatedAsset = generatedAssetForPath(contract, pathname);

  if (generatedAsset) {
    return new Response(generatedAsset.content ?? "", {
      status: 200,
      headers: {
        "content-type": generatedAsset.contentType ?? "text/plain; charset=utf-8"
      }
    });
  }

  if (typeof Bun === "undefined" || typeof Bun.file !== "function") {
    return null;
  }

  const staticAsset = await staticAssetResponse(pathname, contract, options);
  return staticAsset;
}

export function responseForRouteResult(route, result) {
  if (route?.responseKind === "redirect") {
    const redirect = route.encodeResponse(result);
    return redirectResponse(redirect.status ?? 303, redirect.location);
  }

  return new Response(route.encodeResponse(result), {
    status: 200,
    headers: {
      "content-type":
        route?.responseKind === "page"
          ? "text/html; charset=utf-8"
          : "application/json"
    }
  });
}

function jsonResponse(status, payload) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      "content-type": "application/json"
    }
  });
}

function textResponse(status, body) {
  return new Response(body, {
    status,
    headers: {
      "content-type": "text/plain; charset=utf-8"
    }
  });
}

function redirectResponse(status, location) {
  return new Response("", {
    status,
    headers: {
      location
    }
  });
}

function errorResponse(route, status, code, error) {
  const message = errorMessage(error);

  if (route?.responseKind === "page") {
    return textResponse(status, message);
  }

  return jsonResponse(status, {
    error: code,
    message
  });
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}

function generatedAssetForPath(contract, pathname) {
  const assets = contract.staticAssets ?? [];

  return assets.find(
    (asset) => typeof asset?.href === "string" && asset.href === pathname
  ) ?? null;
}

async function staticAssetResponse(pathname, contract, options) {
  const assetBasePath =
    options.assetBasePath ??
    contract.staticAssetStrategy?.assetBasePath ??
    "/assets";
  const staticAssetsDir = options.staticAssetsDir;

  if (typeof staticAssetsDir !== "string" || staticAssetsDir === "") {
    return null;
  }

  const normalizedBasePath = assetBasePath.endsWith("/")
    ? assetBasePath
    : `${assetBasePath}/`;

  if (!pathname.startsWith(normalizedBasePath)) {
    return null;
  }

  const relativePath = pathname.slice(normalizedBasePath.length);

  if (relativePath === "" || relativePath.includes("..")) {
    return null;
  }

  const file = Bun.file(`${staticAssetsDir}/${relativePath}`);

  if (!(await file.exists())) {
    return null;
  }

  return new Response(file);
}

function readSearchParams(searchParams) {
  const entries = {};

  for (const [key, value] of searchParams.entries()) {
    entries[key] = value;
  }

  return entries;
}

function coerceRequestObject(rawValue, schema) {
  if (!schema || schema.kind !== "record") {
    return rawValue;
  }

  const value = isPlainObject(rawValue) ? rawValue : {};
  const coerced = {};

  for (const [fieldName, fieldSchema] of Object.entries(schema.fields ?? {})) {
    if (Object.prototype.hasOwnProperty.call(value, fieldName)) {
      coerced[fieldName] = coerceRequestValue(value[fieldName], unwrapFieldSchema(fieldSchema));
    }
  }

  for (const [fieldName, fieldValue] of Object.entries(value)) {
    if (!Object.prototype.hasOwnProperty.call(coerced, fieldName)) {
      coerced[fieldName] = fieldValue;
    }
  }

  return coerced;
}

function coerceRequestValue(rawValue, schema) {
  if (!schema) {
    return rawValue;
  }

  switch (schema.kind) {
    case "int":
      return maybeParseInt(rawValue);
    case "bool":
      return maybeParseBool(rawValue);
    case "str":
    case "enum":
      return rawValue;
    case "record":
      return coerceRequestObject(rawValue, schema);
    default:
      return rawValue;
  }
}

function unwrapFieldSchema(schema) {
  if (!schema || typeof schema !== "object" || Array.isArray(schema)) {
    return schema;
  }

  return schema.schema ?? schema;
}

function maybeParseInt(rawValue) {
  if (typeof rawValue !== "string" || !/^-?(0|[1-9]\d*)$/.test(rawValue)) {
    return rawValue;
  }

  return Number.parseInt(rawValue, 10);
}

function maybeParseBool(rawValue) {
  if (rawValue === "true") {
    return true;
  }

  if (rawValue === "false") {
    return false;
  }

  return rawValue;
}

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
