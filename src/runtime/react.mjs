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

export function createReactNativeBridge(frontend, options = {}) {
  assertFrontendModule(frontend);

  const platform = normalizePlatform(options.platform);
  const styleRegistry = normalizeStyleRegistry(frontend.__claspStyleIR);
  const renderViewModel = (value) => renderNativeViewModel(value, platform, styleRegistry);
  const renderPageModel = (value) => {
    const page = normalizePageValue(value);
    const head = frontend.__claspPageHead(page);

    return Object.freeze({
      kind: "clasp-native-page",
      version: 1,
      platform,
      title: head?.title ?? page.title ?? "",
      head,
      body: renderNativeViewModel(page.body, platform, styleRegistry)
    });
  };

  return Object.freeze({
    kind: "clasp-native-bridge",
    version: 1,
    platform,
    renderViewModel,
    renderPageModel
  });
}

export function createExpoBridge(frontend, options = {}) {
  return createReactNativeBridge(frontend, {
    ...options,
    platform: "expo"
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

function normalizePlatform(platform) {
  return platform === "expo" ? "expo" : "react-native";
}

function normalizePageValue(value) {
  if (!value || value.$kind !== "page") {
    throw new Error("Expected a generated Clasp Page value for native interop.");
  }

  return value;
}

function renderNativeViewModel(view, platform, styleRegistry) {
  if (!view || typeof view !== "object") {
    throw new Error("Expected a generated Clasp View value for native interop.");
  }

  switch (view.$kind) {
    case "empty":
      return Object.freeze({ kind: "empty" });
    case "text":
      return Object.freeze({ kind: "text", text: view.text ?? "" });
    case "append":
      return Object.freeze({
        kind: "fragment",
        children: flattenNativeChildren(view, platform, styleRegistry)
      });
    case "element":
      return Object.freeze({
        kind: "element",
        tag: view.tag ?? "",
        child: renderNativeViewModel(view.child, platform, styleRegistry)
      });
    case "styled": {
      const styleRef = view.styleRef ?? "";
      const styleEntry = styleRegistry.get(styleRef) ?? null;
      const loweredStyle = resolveNativeStyleTarget(styleEntry, platform);

      return Object.freeze({
        kind: "styled",
        styleRef,
        style: styleEntry
          ? Object.freeze({
              ref: styleEntry.ref ?? styleRef,
              variants: Object.freeze(styleEntry.variants ?? []),
              hostEscapes: styleEntry.hostEscapes ?? null,
              lowered: loweredStyle
            })
          : null,
        child: renderNativeViewModel(view.child, platform, styleRegistry)
      });
    }
    case "link":
      return Object.freeze({
        kind: "link",
        href: view.href ?? "",
        child: renderNativeViewModel(view.child, platform, styleRegistry)
      });
    case "form":
      return Object.freeze({
        kind: "form",
        method: view.method ?? "GET",
        action: view.action ?? "",
        child: renderNativeViewModel(view.child, platform, styleRegistry)
      });
    case "input":
      return Object.freeze({
        kind: "input",
        fieldName: view.fieldName ?? "",
        inputKind: view.inputKind ?? "text",
        value: view.value ?? ""
      });
    case "submit":
      return Object.freeze({
        kind: "submit",
        label: view.label ?? ""
      });
    default:
      throw new Error("Expected a generated Clasp View value for native interop.");
  }
}

function flattenNativeChildren(view, platform, styleRegistry) {
  const children = [];

  appendNativeChild(children, view.left, platform, styleRegistry);
  appendNativeChild(children, view.right, platform, styleRegistry);

  return Object.freeze(children);
}

function appendNativeChild(children, view, platform, styleRegistry) {
  const child = renderNativeViewModel(view, platform, styleRegistry);

  if (child.kind === "fragment") {
    children.push(...child.children);
    return;
  }

  children.push(child);
}

function normalizeStyleRegistry(styleIR) {
  const registry = new Map();
  const styles = Array.isArray(styleIR?.styles) ? styleIR.styles : [];

  for (const style of styles) {
    if (style && typeof style === "object" && typeof style.ref === "string") {
      registry.set(style.ref, style);
    }
  }

  return registry;
}

function resolveNativeStyleTarget(styleEntry, platform) {
  if (!styleEntry || typeof styleEntry !== "object") {
    return null;
  }

  const targetKey = platform === "react-native" ? "reactNative" : platform;
  const target = styleEntry.targets?.[targetKey];
  return target && typeof target === "object" ? target : null;
}
