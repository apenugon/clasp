export function installRuntime(bindings) {
  const previous = globalThis.__claspRuntime ?? {};
  globalThis.__claspRuntime = {
    ...previous,
    ...bindings
  };
}

export function serveCompiledModule(compiledModule, options = {}) {
  if (typeof Bun === "undefined" || typeof Bun.serve !== "function") {
    throw new Error("serveCompiledModule requires Bun.");
  }

  const routes = compiledModule.__claspRoutes ?? [];
  const port = options.port ?? 3301;

  return Bun.serve({
    port,
    async fetch(request) {
      const url = new URL(request.url);
      const route = routes.find(
        (candidate) =>
          candidate.method === request.method && candidate.path === url.pathname
      );

      if (!route) {
        return jsonResponse(404, { error: "not_found" });
      }

      const rawBody =
        request.method === "GET" ? "{}" : (await request.text()) || "{}";

      let payload;
      try {
        payload = route.decodeRequest(rawBody);
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
            "content-type": "application/json"
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
