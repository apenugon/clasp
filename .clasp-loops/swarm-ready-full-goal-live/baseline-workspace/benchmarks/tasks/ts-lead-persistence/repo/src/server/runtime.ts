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

export interface PageRoute<I> {
  method: "GET" | "POST";
  path: string;
  decodeRequest(request: Request): Promise<I>;
  handler(input: I): string | Promise<string>;
}

export function serveRoutes(
  routes: PageRoute<unknown>[],
  options: { port?: number } = {}
) {
  if (!Bun || typeof Bun.serve !== "function") {
    throw new Error("serveRoutes requires Bun.");
  }

  const port = options.port ?? 3302;

  return Bun.serve({
    port,
    async fetch(request) {
      const url = new URL(request.url);
      const route = routes.find(
        (candidate) =>
          candidate.method === request.method && candidate.path === url.pathname
      );

      if (!route) {
        return textResponse(404, "not_found");
      }

      let payload;
      try {
        payload = await route.decodeRequest(request);
      } catch (error) {
        return textResponse(400, errorMessage(error));
      }

      try {
        const html = await route.handler(payload);
        return new Response(html, {
          status: 200,
          headers: {
            "content-type": "text/html; charset=utf-8"
          }
        });
      } catch (error) {
        return textResponse(502, errorMessage(error));
      }
    }
  });
}

function textResponse(status: number, body: string): Response {
  return new Response(body, {
    status,
    headers: {
      "content-type": "text/plain; charset=utf-8"
    }
  });
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
