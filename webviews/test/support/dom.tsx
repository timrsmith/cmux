// Shared JSDOM harness for the React component tests. One module owns the
// DOM globals React reads, the mounted root, and the after-each teardown, so
// every test file installs and restores the same set of globals.

import { afterEach, expect } from "bun:test";
import { JSDOM } from "jsdom";
import { flushSync } from "react-dom";
import { createRoot, type Root } from "react-dom/client";

export type FetchMock = (
  input: RequestInfo | URL,
  init?: RequestInit,
) => Promise<Response> | Response;

const DOM_GLOBAL_KEYS = [
  "window",
  "document",
  "navigator",
  "customElements",
  "ResizeObserver",
  "MutationObserver",
  "getComputedStyle",
  "fetch",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "Worker",
] as const;

// Every DOM interface constructor (`HTMLDivElement`, `SVGElement`,
// `ShadowRoot`, `KeyboardEvent`, ...) that Pierre's components and React
// reach for through `instanceof`. Copied from the JSDOM window wholesale so
// a new component never fails on one more missing class.
const DOM_INTERFACE_PATTERN =
  /^(HTML\w*Element|SVG\w*Element|\w*Event|Node|Text|Comment|Element|Document\w*|ShadowRoot|CSSStyleSheet|Range|Selection|DOMRect\w*|NodeList|HTMLCollection|CharacterData)$/;

const originalGlobals = new Map<string, unknown>();
for (const key of DOM_GLOBAL_KEYS) {
  originalGlobals.set(key, (globalThis as Record<string, unknown>)[key]);
}

function domInterfaceKeys(dom: JSDOM): string[] {
  return Object.getOwnPropertyNames(dom.window).filter((name) =>
    DOM_INTERFACE_PATTERN.test(name),
  );
}

let currentDom: JSDOM | null = null;
let currentRoot: Root | null = null;

/** Fetch stub for tests whose page must never start a network request. */
export function rejectFetch(): never {
  throw new Error("unexpected fetch");
}

/** Fetch stub answering every request with an empty 200. */
export function emptyFetch(): Response {
  return new Response("", { status: 200 });
}

export function createDom(url = "http://127.0.0.1/diff"): JSDOM {
  return new JSDOM(
    "<!doctype html><html><body><div id='root'></div></body></html>",
    { url },
  );
}

/**
 * Points the DOM globals at `dom` until the next `resetDom()` (which the
 * registered after-each hook runs for every test).
 */
export function installDomGlobals(dom: JSDOM, fetchImpl: FetchMock): void {
  const g = globalThis as Record<string, unknown>;
  g.window = dom.window;
  g.document = dom.window.document;
  g.navigator = dom.window.navigator;
  const windowRecord = dom.window as unknown as Record<string, unknown>;
  for (const key of domInterfaceKeys(dom)) {
    if (!originalGlobals.has(key)) {
      originalGlobals.set(key, g[key]);
    }
    g[key] = windowRecord[key];
  }
  g.customElements = dom.window.customElements;
  g.MutationObserver = dom.window.MutationObserver;
  g.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  // JSDOM has no ResizeObserver; Pierre's CodeView observes its container
  // and only needs the constructor to exist to render its initial range.
  const resizeObserver = class {
    observe(): void {}
    unobserve(): void {}
    disconnect(): void {}
  };
  g.ResizeObserver = resizeObserver;
  windowRecord.ResizeObserver = resizeObserver;
  // Pierre's highlighter pool spawns module workers from the page URL, which
  // Bun cannot load here. A silent worker leaves the rendered plain text in
  // place (highlighting never arrives) without logging load errors.
  const silentWorker = class {
    onmessage: unknown = null;
    onerror: unknown = null;
    postMessage(): void {}
    terminate(): void {}
    addEventListener(): void {}
    removeEventListener(): void {}
    dispatchEvent(): boolean {
      return true;
    }
  };
  g.Worker = silentWorker;
  windowRecord.Worker = silentWorker;
  // A focused input makes React run its legacy IE onpropertychange polyfill
  // (JSDOM misreports 'input' support), which calls attach/detachEvent on the
  // active element. JSDOM lacks them; stub no-ops on Element.prototype.
  const elementProto = dom.window.Element.prototype as unknown as {
    attachEvent: () => void;
    detachEvent: () => void;
  };
  elementProto.attachEvent = () => {};
  elementProto.detachEvent = () => {};
  // JSDOM implements no Element.scrollTo; Pierre's CodeView calls it when
  // the viewer scrolls to a file, so navigating in a test needs a no-op.
  const scrollable = dom.window.Element.prototype as unknown as {
    scrollTo?: (options?: ScrollToOptions) => void;
  };
  scrollable.scrollTo ??= () => {};
  g.fetch = fetchImpl;
  g.requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(performance.now()), 0);
  g.cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  currentDom = dom;
}

/** `createDom` + `installDomGlobals` in one step. */
export function mountDom(
  url?: string,
  fetchImpl: FetchMock = rejectFetch,
): JSDOM {
  const dom = createDom(url);
  installDomGlobals(dom, fetchImpl);
  return dom;
}

/** Renders `element` into the current DOM's `#root`, replacing any mounted root. */
export function render(element: React.ReactNode): void {
  const container = currentDom?.window.document.getElementById("root");
  expect(container).toBeTruthy();
  unmountRoot();
  currentRoot = createRoot(container!);
  flushSync(() => {
    currentRoot?.render(element);
  });
}

/** Re-renders the mounted root with `element` (same root, new props). */
export function rerender(element: React.ReactNode): void {
  expect(currentRoot).toBeTruthy();
  flushSync(() => {
    currentRoot?.render(element);
  });
}

export function unmountRoot(): void {
  if (currentRoot) {
    const root = currentRoot;
    flushSync(() => root.unmount());
  }
  currentRoot = null;
}

/** Unmounts, closes the window, and restores the original globals. */
export async function resetDom(): Promise<void> {
  unmountRoot();
  await new Promise((resolve) => setTimeout(resolve, 0));
  currentDom?.window.close();
  currentDom = null;
  const g = globalThis as Record<string, unknown>;
  for (const [key, value] of originalGlobals) {
    if (value === undefined) {
      delete g[key];
    } else {
      g[key] = value;
    }
  }
}

/**
 * Registers the after-each teardown for the calling test file. Bun evaluates
 * a shared module once per process, so the hook is registered per file
 * rather than at import time.
 */
export function registerDomCleanup(): void {
  afterEach(resetDom);
}


export function click(button: HTMLButtonElement | null | undefined): void {
  expect(button).toBeTruthy();
  flushSync(() => button?.click());
}

export function findButton(
  document: Document,
  text: string,
  within = "body",
): HTMLButtonElement | undefined {
  return Array.from(
    document.querySelectorAll<HTMLButtonElement>(`${within} button`),
  ).find((button) => button.textContent?.trim() === text);
}

export function setTextareaValue(
  textarea: HTMLTextAreaElement,
  value: string,
): void {
  expect(currentDom).toBeTruthy();
  const window = currentDom!.window;
  // React tracks the value through its own setter; write through the native
  // prototype so the change event carries the new value.
  const descriptor = Object.getOwnPropertyDescriptor(
    window.HTMLTextAreaElement.prototype,
    "value",
  );
  descriptor?.set?.call(textarea, value);
  // React loaded without a DOM, so it runs its legacy input polyfill: text
  // changes are detected on keyup/selectionchange of the focused element, not
  // on `input`. Focus first, then key up, to hit that path deterministically.
  flushSync(() => {
    textarea.dispatchEvent(new window.Event("focusin", { bubbles: true }));
    textarea.dispatchEvent(
      new window.KeyboardEvent("keyup", { bubbles: true, key: "t" }),
    );
  });
}

export async function waitFor(
  predicate: () => boolean,
  what = "assertion",
  timeoutMs = 1000,
): Promise<void> {
  const timeoutAt = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() > timeoutAt) {
      throw new Error(`Timed out waiting for ${what}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}
