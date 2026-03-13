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
    const hostBindings = contract.hostBindings ?? compiledModule?.__claspHostBindings ?? [];
    return {
      ...contract,
      module: contract.module ?? compiledModule?.__claspModule ?? null,
      hostBindings,
      providers:
        contract.providers ?? defaultProviderContract(compiledModule, hostBindings),
      nativeInterop:
        contract.nativeInterop ??
        compiledModule?.__claspNativeInterop ??
        defaultNativeInterop(hostBindings),
      evalHooks: contract.evalHooks ?? compiledModule?.__claspEvalHooks ?? null,
      traces: contract.traces ?? compiledModule?.__claspTraceCollector ?? null
    };
  }

  const hostBindings = compiledModule?.__claspHostBindings ?? [];

  return {
    kind: "clasp-generated-bindings",
    version: 1,
    module: compiledModule?.__claspModule ?? null,
    hostBindings,
    providers: defaultProviderContract(compiledModule, hostBindings),
    nativeInterop:
      compiledModule?.__claspNativeInterop ??
      defaultNativeInterop(hostBindings),
    packageImports: compiledModule?.__claspPackageImports ?? [],
    routes: compiledModule?.__claspRoutes ?? [],
    routeClients: compiledModule?.__claspRouteClients ?? [],
    schemas: compiledModule?.__claspSchemas ?? {},
    platformBridges:
      compiledModule?.__claspPlatformBridges ?? defaultPlatformBridges(),
    python: compiledModule?.__claspPythonInterop ?? null,
    seededFixtures: compiledModule?.__claspSeededFixtures ?? [],
    staticAssetStrategy:
      compiledModule?.__claspStaticAssetStrategy ?? {
        assetBasePath: "/assets",
        generatedAssetBasePath: "/assets/clasp"
      },
    staticAssets: compiledModule?.__claspStaticAssets ?? [],
    styleIR: compiledModule?.__claspStyleIR ?? null,
    styleBundles: compiledModule?.__claspStyleBundles ?? [],
    headStrategy:
      compiledModule?.__claspHeadStrategy ?? {
        charset: "utf-8",
        viewport: "width=device-width, initial-scale=1"
      },
    uiGraph: compiledModule?.__claspUiGraph ?? [],
    navigationGraph: compiledModule?.__claspNavigationGraph ?? [],
    actionGraph: compiledModule?.__claspActionGraph ?? [],
    evalHooks: compiledModule?.__claspEvalHooks ?? null,
    traces: compiledModule?.__claspTraceCollector ?? null
  };
}

function defaultProviderContract(compiledModule, hostBindings) {
  const bindings = (hostBindings ?? [])
    .map((binding) => defaultProviderBinding(compiledModule, binding))
    .filter((binding) => binding !== null);
  const providerMap = new Map();

  for (const binding of bindings) {
    const current =
      providerMap.get(binding.provider) ??
      {
        name: binding.provider,
        runtimeNames: [],
        bindingNames: []
      };

    current.runtimeNames.push(binding.runtimeName);
    current.bindingNames.push(binding.name);
    providerMap.set(binding.provider, current);
  }

  return Object.freeze({
    kind: "clasp-provider-contract",
    version: 1,
    providers: Object.freeze(
      Array.from(providerMap.values(), (provider) =>
        Object.freeze({
          name: provider.name,
          runtimeNames: Object.freeze(provider.runtimeNames),
          bindingNames: Object.freeze(provider.bindingNames)
        })
      )
    ),
    bindings: Object.freeze(bindings)
  });
}

function defaultProviderBinding(compiledModule, binding) {
  const descriptor = parseProviderRuntimeName(binding?.runtimeName);

  if (!descriptor) {
    return null;
  }

  return Object.freeze({
    name: binding?.name ?? descriptor.operation,
    runtimeName: binding?.runtimeName ?? `${descriptor.namespace}:${descriptor.operation}`,
    provider: descriptor.provider,
    namespace: descriptor.namespace,
    operation: descriptor.operation,
    capability: Object.freeze({
      id: `capability:provider:${descriptor.provider}:${descriptor.operation}`,
      kind: "model-runtime-operation",
      provider: descriptor.provider,
      operation: descriptor.operation,
      runtimeName: binding?.runtimeName ?? `${descriptor.namespace}:${descriptor.operation}`
    }),
    secretConsumer(boundary = null) {
      return createProviderSecretConsumerSurface(
        compiledModule,
        binding?.name ?? descriptor.operation,
        descriptor,
        boundary
      );
    },
    params: Object.freeze(binding?.params ?? []),
    returns: binding?.returns ?? null
  });
}

function parseProviderRuntimeName(runtimeName) {
  if (typeof runtimeName !== "string") {
    return null;
  }

  const parts = runtimeName.split(":");

  if (parts[0] !== "provider" || parts.length < 2) {
    return null;
  }

  if (parts.length === 2) {
    return {
      namespace: "provider",
      provider: "provider",
      operation: parts[1]
    };
  }

  return {
    namespace: parts[0],
    provider: parts[1],
    operation: parts.slice(2).join(":")
  };
}

export function providerContractFor(compiledModule) {
  return bindingContractFor(compiledModule).providers;
}

export function createProviderRuntime(compiledModule, options = {}) {
  if (!compiledModule || typeof compiledModule.__claspAdaptHostBindings !== "function") {
    throw new Error("createProviderRuntime requires a generated Clasp module.");
  }

  const runtimeOptions = normalizeProviderRuntimeOptions(options);
  const contract = providerContractFor(compiledModule);
  const bindingMap = new Map(contract.bindings.map((binding) => [binding.name, binding]));
  const runtimeBindingMap = new Map(
    contract.bindings.map((binding) => [binding.runtimeName, binding])
  );
  const implementations = {};

  for (const binding of contract.bindings) {
    const implementation = (...args) =>
      invokeProviderBinding(compiledModule, binding, args, runtimeOptions);
    implementations[binding.name] = implementation;
    implementations[binding.runtimeName] = implementation;
  }

  const runtime = {
    contract,
    providers: contract.providers,
    bindings: contract.bindings,
    implementations: Object.freeze(implementations),
    binding(name) {
      const found = bindingMap.get(name) ?? runtimeBindingMap.get(name) ?? null;

      if (!found) {
        throw new Error(`Unknown Clasp provider binding: ${String(name)}`);
      }

      return found;
    },
    call(name, ...args) {
      const binding = this.binding(name);
      return invokeProviderBinding(compiledModule, binding, args, runtimeOptions);
    },
    install() {
      const adaptedBindings =
        compiledModule.__claspAdaptHostBindings(this.implementations);
      installRuntime(adaptedBindings);
      return adaptedBindings;
    }
  };

  return Object.freeze(runtime);
}

export function installProviderRuntime(compiledModule, options = {}) {
  return createProviderRuntime(compiledModule, options).install();
}

function invokeProviderBinding(compiledModule, binding, args, runtimeOptions) {
  const provider = resolveProviderImplementation(binding, runtimeOptions.providers);
  const secretConsumer = binding.secretConsumer(
    resolveProviderSecretBoundary(binding, runtimeOptions)
  );
  return provider({
    id: `provider:${binding.provider}:${binding.operation}`,
    binding,
    provider: binding.provider,
    operation: binding.operation,
    args: Object.freeze(args.slice()),
    secretConsumer,
    secretHandles: secretConsumer.secretHandles,
    resolveSecret(secretHandleOrName, options = null) {
      return secretConsumer.resolve(secretHandleOrName, runtimeOptions.secrets, options);
    },
    resolveAllSecrets(options = null) {
      return secretConsumer.resolveAll(runtimeOptions.secrets, options);
    }
  });
}

function resolveProviderImplementation(binding, providers) {
  const provider = providers?.[binding.provider];

  if (provider && typeof provider.invoke === "function") {
    return (request) => provider.invoke(request);
  }

  if (provider && typeof provider[binding.operation] === "function") {
    return (request) => provider[binding.operation](...request.args, request);
  }

  if (typeof provider === "function") {
    return (request) => provider(request);
  }

  throw new Error(
    `Missing Clasp provider implementation for ${binding.provider}:${binding.operation}`
  );
}

function normalizeProviderRuntimeOptions(options) {
  if (!options || typeof options !== "object" || Array.isArray(options)) {
    return {
      providers: {},
      secrets: null,
      secretBoundary: null,
      secretBoundaryFor: null
    };
  }

  if (
    Object.prototype.hasOwnProperty.call(options, "providers") ||
    Object.prototype.hasOwnProperty.call(options, "secrets") ||
    Object.prototype.hasOwnProperty.call(options, "secretBoundary") ||
    Object.prototype.hasOwnProperty.call(options, "secretBoundaryFor")
  ) {
    return {
      providers: options.providers ?? {},
      secrets: options.secrets ?? null,
      secretBoundary: options.secretBoundary ?? null,
      secretBoundaryFor:
        typeof options.secretBoundaryFor === "function"
          ? options.secretBoundaryFor
          : null
    };
  }

  return {
    providers: options,
    secrets: null,
    secretBoundary: null,
    secretBoundaryFor: null
  };
}

function resolveProviderSecretBoundary(binding, runtimeOptions) {
  if (typeof runtimeOptions.secretBoundaryFor === "function") {
    const resolved = runtimeOptions.secretBoundaryFor(binding);
    if (resolved !== undefined) {
      return resolved ?? null;
    }
  }

  return runtimeOptions.secretBoundary ?? null;
}

function createProviderSecretConsumerSurface(
  compiledModule,
  bindingName,
  descriptor,
  boundary = null
) {
  const createSecretConsumer = compiledModule?.__claspCreateSecretConsumerSurface;

  if (typeof createSecretConsumer !== "function") {
    throw new Error(
      "Generated Clasp module does not expose secret-consumer helpers."
    );
  }

  return createSecretConsumer({
    kind: "provider",
    name: bindingName,
    id: `provider:${descriptor.provider}:${descriptor.operation}`,
    boundary,
    secretNames: Array.isArray(boundary?.secretNames) ? boundary.secretNames : []
  });
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
