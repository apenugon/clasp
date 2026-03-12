export function createReactInterop(frontend, reactRuntime = {}) {
  assertFrontendModule(frontend);

  const createElement = resolveCreateElement(reactRuntime);
  const renderHead = (value) => renderHeadElements(frontend.__claspPageHead(value), createElement);
  const renderPage = (value, options = {}) => {
    const renderMode =
      options.renderMode ?? frontend.__claspPageRenderModes?.html;
    const html = frontend.__claspRenderPage(value, renderMode);
    const head = frontend.__claspPageHead(value);
    const bodyHtml = extractBodyHtml(html);

    return {
      html,
      bodyHtml,
      head,
      headElements: renderHeadElements(head, createElement),
      element: createElement("div", {
        "data-clasp-page-root": "",
        dangerouslySetInnerHTML: { __html: bodyHtml }
      })
    };
  };

  function Page(props = {}) {
    return renderPage(props.value, props).element;
  }

  return Object.freeze({
    Page,
    renderHead,
    renderPage
  });
}

function assertFrontendModule(frontend) {
  if (
    !frontend ||
    typeof frontend.__claspRenderPage !== "function" ||
    typeof frontend.__claspPageHead !== "function"
  ) {
    throw new Error(
      "Expected a generated Clasp frontend module with page render helpers."
    );
  }
}

function resolveCreateElement(reactRuntime) {
  const createElement =
    reactRuntime?.createElement ?? reactRuntime?.default?.createElement;

  if (typeof createElement !== "function") {
    throw new Error(
      "Missing React createElement implementation for Clasp React interop."
    );
  }

  return createElement;
}

function renderHeadElements(head, createElement) {
  const elements = [];

  if (typeof head?.title === "string" && head.title !== "") {
    elements.push(createElement("title", { key: "title" }, head.title));
  }

  for (const [index, entry] of normalizeEntries(head?.meta).entries()) {
    elements.push(
      createElement("meta", {
        key: `meta:${index}`,
        ...entry
      })
    );
  }

  for (const [index, entry] of normalizeEntries(head?.links).entries()) {
    elements.push(
      createElement("link", {
        key: `link:${index}`,
        ...entry
      })
    );
  }

  return elements;
}

function normalizeEntries(entries) {
  return Array.isArray(entries)
    ? entries.filter(
        (entry) => entry && typeof entry === "object" && !Array.isArray(entry)
      )
    : [];
}

function extractBodyHtml(html) {
  if (typeof html !== "string") {
    return "";
  }

  const match = html.match(/<body[^>]*>([\s\S]*)<\/body>/i);
  return match ? match[1] : html;
}
