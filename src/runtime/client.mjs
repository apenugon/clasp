export function createRouteClientRuntime(options = {}) {
  return {
    prepare(client, value, requestOptions = {}) {
      return prepareRouteFetch(client, value, mergeRouteClientOptions(options, requestOptions));
    },
    async call(client, value, requestOptions = {}) {
      return callRouteClient(client, value, mergeRouteClientOptions(options, requestOptions));
    },
    async fetch(client, value, requestOptions = {}) {
      return fetchRouteClient(client, value, mergeRouteClientOptions(options, requestOptions));
    }
  };
}

export function prepareRouteFetch(client, value, options = {}) {
  assertRouteClient(client);

  const request = client.prepareRequest(value);
  const fetchImpl = resolveFetch(options.fetch);
  const baseUrl = resolveBaseUrl(options.baseUrl);
  const headers = {
    ...(normalizeHeaders(options.init?.headers) ?? {}),
    ...(request.headers ?? {})
  };
  const body = request.body === null ? undefined : request.body;
  const init = {
    ...options.init,
    method: request.method,
    headers
  };

  if (body !== undefined) {
    init.body = body;
  } else {
    delete init.body;
  }

  if (init.credentials === undefined) {
    init.credentials = "same-origin";
  }

  if (init.redirect === undefined && client.responseKind === "redirect") {
    init.redirect = "manual";
  }

  return {
    request,
    url: new URL(request.href, baseUrl).toString(),
    init,
    fetch: fetchImpl
  };
}

export async function fetchRouteClient(client, value, options = {}) {
  const prepared = prepareRouteFetch(client, value, options);
  const response = await prepared.fetch(prepared.url, prepared.init);
  const parseTarget =
    typeof response?.clone === "function" ? response.clone() : response;

  return {
    request: prepared.request,
    url: prepared.url,
    init: prepared.init,
    response,
    data: await client.parseResponse(parseTarget)
  };
}

export async function callRouteClient(client, value, options = {}) {
  const result = await fetchRouteClient(client, value, options);
  return result.data;
}

function mergeRouteClientOptions(baseOptions, requestOptions) {
  return {
    ...baseOptions,
    ...requestOptions,
    init: {
      ...(baseOptions.init ?? {}),
      ...(requestOptions.init ?? {})
    }
  };
}

function assertRouteClient(client) {
  if (!client || typeof client.prepareRequest !== "function" || typeof client.parseResponse !== "function") {
    throw new Error("Expected a generated Clasp route client.");
  }
}

function resolveFetch(fetchImpl) {
  const foundFetch = fetchImpl ?? globalThis.fetch;

  if (typeof foundFetch !== "function") {
    throw new Error("Missing fetch implementation for Clasp route client runtime.");
  }

  return foundFetch;
}

function resolveBaseUrl(baseUrl) {
  if (typeof baseUrl === "string" && baseUrl !== "") {
    return baseUrl;
  }

  const windowHref = globalThis.window?.location?.href;

  if (typeof windowHref === "string" && windowHref !== "") {
    return windowHref;
  }

  return "http://clasp.local/";
}

function normalizeHeaders(headers) {
  if (!headers) {
    return null;
  }

  if (headers instanceof Headers) {
    return Object.fromEntries(headers.entries());
  }

  if (Array.isArray(headers)) {
    return Object.fromEntries(headers);
  }

  return headers;
}
