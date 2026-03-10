declare const Bun:
  | {
      serve(options: {
        port: number;
        fetch(request: Request): Response | Promise<Response>;
      }): {
        port: number;
        stop(force?: boolean): void;
      };
    }
  | undefined;

export interface JsonRoute<I, O> {
  method: string;
  path: string;
  decodeRequest(body: string): I;
  encodeResponse(value: O): string;
  handler(input: I): O | Promise<O>;
}

export function serveRoutes(
  routes: JsonRoute<unknown, unknown>[],
  options: { port?: number } = {}
) {
  if (!Bun || typeof Bun.serve !== "function") {
    throw new Error("serveRoutes requires Bun.");
  }

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

function jsonResponse(status: number, payload: unknown): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      "content-type": "application/json"
    }
  });
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
