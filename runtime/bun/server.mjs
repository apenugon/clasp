export function installRuntime(bindings) {
  const previous = globalThis.__claspRuntime ?? {};
  globalThis.__claspRuntime = {
    ...previous,
    ...bindings
  };
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

  const routes = compiledModule.__claspRoutes ?? [];
  const port = options.port ?? 3001;

  return Bun.serve({
    port,
    async fetch(request) {
      const url = new URL(request.url);
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
        return jsonResponse(400, {
          error: "invalid_request",
          message: errorMessage(error)
        });
      }

      let result;
      try {
        result = await route.handler(payload);
      } catch (error) {
        return jsonResponse(502, {
          error: "handler_failed",
          message: errorMessage(error)
        });
      }

      try {
        return new Response(route.encodeResponse(result), {
          status: 200,
          headers: {
            "content-type":
              route.responseKind === "page"
                ? "text/html; charset=utf-8"
                : "application/json"
          }
        });
      } catch (error) {
        return jsonResponse(500, {
          error: "invalid_response",
          message: errorMessage(error)
        });
      }
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

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
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
      coerced[fieldName] = coerceRequestValue(value[fieldName], fieldSchema);
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
