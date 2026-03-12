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
    return contract;
  }

  return {
    kind: "clasp-generated-bindings",
    version: 1,
    hostBindings: compiledModule?.__claspHostBindings ?? [],
    routes: compiledModule?.__claspRoutes ?? [],
    routeClients: compiledModule?.__claspRouteClients ?? [],
    schemas: compiledModule?.__claspSchemas ?? {},
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

export function installCompiledModule(compiledModule, implementations = {}) {
  if (!compiledModule || typeof compiledModule.__claspAdaptHostBindings !== "function") {
    throw new Error("installCompiledModule requires a generated Clasp module.");
  }

  const runtimeBindings = compiledModule.__claspAdaptHostBindings(implementations);
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
