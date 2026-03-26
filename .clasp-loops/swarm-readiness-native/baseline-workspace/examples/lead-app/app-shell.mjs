const DEFAULT_DOCUMENT_URL = "https://app.example.test/";

export function createLeadAppShell(options = {}) {
  const doc = resolveDocument(options.document);
  const win = resolveWindow(options.window, doc);
  const fetchImpl = resolveFetch(options.fetch);
  const root = options.root ?? doc.body;
  const appRoot = root ?? doc.body;
  let currentHref = normalizeHref(options.initialHref ?? win.location?.href ?? doc.location?.href);
  let started = false;

  async function start() {
    if (started) {
      return shell;
    }

    started = true;

    if (typeof win.addEventListener === "function") {
      win.addEventListener("popstate", handlePopState);
    }

    return shell;
  }

  async function navigate(targetHref, navigationOptions = {}) {
    const requestHref = toAbsoluteHref(targetHref, currentHref);
    const response = await fetchPage(requestHref, {
      method: "GET"
    });

    commitRender(response.html, response.url, {
      history: navigationOptions.history ?? "push"
    });

    return response;
  }

  async function submit(submission, navigationOptions = {}) {
    const request = normalizeSubmission(submission, currentHref);
    const response = await fetchPage(request.url, request.init);

    commitRender(response.html, currentHref, {
      history: navigationOptions.history ?? "none"
    });

    return response;
  }

  async function reload() {
    const reloadHref = readCurrentHref(win, doc, currentHref);
    const response = await fetchPage(reloadHref, {
      method: "GET"
    });

    commitRender(response.html, reloadHref, {
      history: "replace"
    });

    return response;
  }

  async function handlePopState() {
    await reload();
  }

  async function fetchPage(targetHref, init) {
    const response = await fetchImpl(targetHref, init);
    const resolvedUrl =
      typeof response?.url === "string" && response.url !== ""
        ? response.url
        : targetHref;

    return {
      url: normalizeHref(resolvedUrl),
      html: await response.text()
    };
  }

  function commitRender(html, nextHref, options = {}) {
    currentHref = normalizeHref(nextHref);
    updateDocumentLocation(doc, currentHref);
    updateWindowLocation(win, currentHref);
    renderHtmlIntoDocument(doc, appRoot, html);
    applyHistory(win, currentHref, options.history ?? "push");
  }

  const shell = {
    start,
    navigate,
    submit,
    reload,
    get currentHref() {
      return currentHref;
    }
  };

  return shell;
}

export async function startLeadAppShell(options = {}) {
  const shell = createLeadAppShell(options);
  await shell.start();
  return shell;
}

function resolveDocument(doc) {
  if (doc) {
    return doc;
  }

  if (globalThis.document) {
    return globalThis.document;
  }

  return {
    title: "",
    body: { innerHTML: "" },
    location: createLocation(DEFAULT_DOCUMENT_URL)
  };
}

function resolveWindow(win, doc) {
  if (win) {
    return win;
  }

  if (globalThis.window) {
    return globalThis.window;
  }

  return {
    location: doc.location ?? createLocation(DEFAULT_DOCUMENT_URL),
    history: {
      pushState() {},
      replaceState() {}
    },
    addEventListener() {}
  };
}

function resolveFetch(fetchImpl) {
  const foundFetch = fetchImpl ?? globalThis.fetch;

  if (typeof foundFetch !== "function") {
    throw new Error("Missing fetch implementation for the lead app shell.");
  }

  return foundFetch;
}

function normalizeSubmission(submission, currentHref) {
  if (!submission || typeof submission !== "object") {
    throw new Error("Expected a form submission descriptor.");
  }

  const method = String(submission.method ?? "GET").toUpperCase();
  const url = toAbsoluteHref(submission.action ?? currentHref, currentHref);
  const body = serializeSubmissionBody(submission);
  const headers =
    method === "GET"
      ? undefined
      : {
          "content-type": "application/x-www-form-urlencoded"
        };

  return {
    url,
    init: {
      method,
      headers,
      body
    }
  };
}

function serializeSubmissionBody(submission) {
  if (submission.body !== undefined) {
    return submission.body;
  }

  if (!submission.fields) {
    return undefined;
  }

  return new URLSearchParams(submission.fields).toString();
}

function renderHtmlIntoDocument(doc, root, html) {
  doc.title = extractTagText(html, "title") ?? doc.title;
  root.innerHTML = extractBodyHtml(html) ?? html;
}

function extractBodyHtml(html) {
  const match = /<body[^>]*>([\s\S]*)<\/body>/i.exec(html);
  return match ? match[1] : null;
}

function extractTagText(html, tagName) {
  const match = new RegExp(`<${tagName}[^>]*>([\\s\\S]*?)<\\/${tagName}>`, "i").exec(html);
  return match ? match[1].trim() : null;
}

function applyHistory(win, href, mode) {
  if (!win?.history) {
    return;
  }

  if (mode === "push" && typeof win.history.pushState === "function") {
    win.history.pushState({ href }, "", href);
    return;
  }

  if (mode === "replace" && typeof win.history.replaceState === "function") {
    win.history.replaceState({ href }, "", href);
  }
}

function updateDocumentLocation(doc, href) {
  if (!doc.location) {
    doc.location = createLocation(href);
    return;
  }

  doc.location.href = href;
  doc.location.pathname = new URL(href).pathname;
}

function updateWindowLocation(win, href) {
  if (!win.location) {
    win.location = createLocation(href);
    return;
  }

  win.location.href = href;
  win.location.pathname = new URL(href).pathname;
}

function createLocation(href) {
  const url = new URL(href);
  return {
    href: url.toString(),
    pathname: url.pathname
  };
}

function normalizeHref(href) {
  return new URL(href, DEFAULT_DOCUMENT_URL).toString();
}

function toAbsoluteHref(targetHref, baseHref) {
  return new URL(targetHref, baseHref).toString();
}

function readCurrentHref(win, doc, fallbackHref) {
  const foundHref = win?.location?.href ?? doc?.location?.href ?? fallbackHref;
  return normalizeHref(foundHref);
}
