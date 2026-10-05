import { expect, test } from "bun:test";
import { flushSync } from "react-dom";
import { App } from "../src/App";
import { createDiffViewerStatus } from "../src/status";
import { patchFingerprint } from "../src/viewed-files";
import { click, mountDom, registerDomCleanup, render, waitFor } from "./support/dom";
import {
  MOCK_CAPABILITY_TOKEN as token,
  sidecarMock,
  type SidecarRequest,
} from "./support/sidecar-mock";

// The "Viewed" review marker belongs to the review views (a branch, a patch,
// a turn): the working-tree views of the user's own edits render none of its
// UI and ignore the stored marks, which stay persisted for the review views.

registerDomCleanup();

const viewerURL = `cmux-diff-viewer://${token}/viewer.html`;
const unstagedSource = { kind: "unstaged", repoRoot: "/tmp/repo" };
const stagedSource = { kind: "staged", repoRoot: "/tmp/repo" };
const branchSource = { kind: "branch", repoRoot: "/tmp/repo", baseRef: "main" };
const patchSource = { kind: "patch", path: "/last-turn.patch" };

/** `story.txt` with one hunk, as the sidecar streams it. */
const STORY_PATCH = `diff --git a/story.txt b/story.txt
index 1111111..2222222 100644
--- a/story.txt
+++ b/story.txt
@@ -1,3 +1,3 @@
 one
-two
+two changed
 three
`;

/** `story.txt` followed by `notes.txt`, each with one hunk. */
const TWO_FILE_PATCH = `${STORY_PATCH}diff --git a/notes.txt b/notes.txt
index 3333333..4444444 100644
--- a/notes.txt
+++ b/notes.txt
@@ -1,2 +1,2 @@
 alpha
-beta
+beta changed
`;

/** The stored mark of `story.txt`, at the fingerprint of its streamed patch. */
const STORY_VIEWED = { path: "story.txt", fingerprint: patchFingerprint(STORY_PATCH) };

/** A branch view and the unstaged view of the same repository, for the source picker. */
const PICKER_OPTIONS = {
  sourceOptions: [
    { label: "Branch", value: "branch", sessionSource: branchSource },
    { label: "Unstaged", value: "unstaged", sessionSource: unstagedSource },
  ],
  repoOptions: [{ label: "repo", value: "/tmp/repo", sessionSource: unstagedSource }],
};

type BridgeRequest = { method: string; params: any };

/**
 * Mounts the App on a typed WebKit session for `source`, streaming both files
 * with `story.txt` marked viewed in the persisted state, and waits for the
 * cards and for the stored marks to have been requested and applied.
 */
async function renderViewed(source: any, payloadExtras: Record<string, unknown> = {}) {
  const requests: SidecarRequest[] = [];
  const bridgeRequests: BridgeRequest[] = [];
  const dom = mountDom(viewerURL, () => new Response(TWO_FILE_PATCH, { status: 200 }));
  (dom.window as any).webkit = {
    messageHandlers: {
      cmuxDiff: sidecarMock(requests, []),
      cmuxDiffComments: {
        async postMessage(request: BridgeRequest) {
          bridgeRequests.push(request);
          if (request.method === "viewedFiles.list") {
            return { ok: true, value: { files: [STORY_VIEWED] } };
          }
          return { ok: true, value: { comments: [], preferences: {} } };
        },
      },
    },
  };
  render(
    <App
      config={{
        payload: {
          capabilityToken: token,
          pendingReplacement: true,
          repoRoot: "/tmp/repo",
          sessionSource: source,
          statusMessage: "Loading diff",
          transport: { kind: "webKit", endpoint: "cmuxDiff", protocolVersion: 1 },
          ...payloadExtras,
        },
      }}
      initialStatus={createDiffViewerStatus("Loading diff", { loading: true, pending: true })}
    />,
  );
  const document = dom.window.document;
  await waitFor(() => cards(document).length === 2, "both cards", 3000);
  await waitForStoredMarks(document, bridgeRequests, viewedScopeSource(source));
  return { document, requests, bridgeRequests };
}

/** The `source` of the stored-marks scope the App requests for a session source. */
function viewedScopeSource(source: any): string {
  switch (source.kind) {
  case "branch": return `branch:${source.baseRef}`;
  case "patch": return `patch:${source.path}`;
  default: return source.kind;
  }
}

/**
 * The stored marks are requested for every source (keyed by its scope); the
 * view decides whether they apply. Waits for the request for `scopeSource`,
 * for its reply to have been applied, and for the tree rows.
 */
async function waitForStoredMarks(document: Document, bridgeRequests: BridgeRequest[], scopeSource: string): Promise<void> {
  await waitFor(
    () => bridgeRequests.some((request) => request.method === "viewedFiles.list" && request.params.scope.source === scopeSource),
    `the stored marks request for ${scopeSource}`,
  );
  await new Promise((resolve) => setTimeout(resolve, 20));
  await waitFor(() => treeRow(document, "story.txt") != null, "the tree rows");
}

function cards(document: Document): HTMLElement[] {
  return Array.from(document.querySelectorAll<HTMLElement>("diffs-container"));
}

/** The cards stream in patch order: `story.txt` first, `notes.txt` second. */
function cardOf(document: Document, name: "story.txt" | "notes.txt"): HTMLElement {
  const card = cards(document)[name === "story.txt" ? 0 : 1];
  expect(card).toBeTruthy();
  return card!;
}

function isExpanded(card: HTMLElement): boolean {
  const toggle = card.querySelector<HTMLButtonElement>(".file-collapse-toggle");
  expect(toggle).toBeTruthy();
  return toggle!.getAttribute("aria-expanded") === "true";
}

function treeShadow(document: Document): ShadowRoot | null {
  return document.querySelector("file-tree-container")?.shadowRoot ?? null;
}

function treeRow(document: Document, name: string): HTMLElement | null {
  return treeShadow(document)?.querySelector<HTMLElement>(`[data-item-type="file"][data-item-path="${name}"]`) ?? null;
}

function rowDecoration(document: Document, name: string): string {
  return treeRow(document, name)?.querySelector('[data-item-section="decoration"]')?.textContent ?? "";
}

/**
 * Right-clicks the row of `name` and returns the context menu the tree
 * rendered, once the tree has had a frame to open it; `null` when it opened none.
 */
async function openRowContextMenu(document: Document, name: string): Promise<HTMLElement | null> {
  const row = treeRow(document, name);
  expect(row).toBeTruthy();
  const window = document.defaultView!;
  flushSync(() => {
    row!.dispatchEvent(
      new window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, composed: true, clientX: 12, clientY: 12 }),
    );
  });
  await new Promise((resolve) => setTimeout(resolve, 50));
  return document.querySelector<HTMLElement>(".file-tree-context-menu");
}

function count(document: Document, selector: string): number {
  return document.querySelectorAll(selector).length;
}

/** Double-clicks `target` (composed, as a real double-click is) and reports whether the page prevented its default. */
function doubleClick(target: Element | null | undefined): boolean {
  expect(target).toBeTruthy();
  const window = target!.ownerDocument.defaultView!;
  let prevented = false;
  flushSync(() => {
    prevented = !target!.dispatchEvent(
      new window.MouseEvent("dblclick", { bubbles: true, cancelable: true, composed: true }),
    );
  });
  return prevented;
}

const workingTreeSources = [
  ["unstaged", unstagedSource],
  ["staged", stagedSource],
] as const;

const reviewSources = [
  ["branch", branchSource],
  ["patch", patchSource],
] as const;

for (const [kind, source] of workingTreeSources) {
  test(`the ${kind} view renders no Viewed marks and ignores the stored ones`, async () => {
    const { document, bridgeRequests } = await renderViewed(source);
    expect(bridgeRequests.find((request) => request.method === "viewedFiles.list")?.params)
      .toEqual({ scope: { repoRoot: "/tmp/repo", source: kind } });
    // No card-header control or badge, no progress, no filter toggle.
    expect(count(document, ".file-review-controls")).toBe(0);
    expect(count(document, ".file-review-viewed")).toBe(0);
    expect(count(document, "[data-changed-since-viewed]")).toBe(0);
    expect(count(document, "#files-viewed-progress")).toBe(0);
    expect(document.body.textContent).not.toContain("files viewed");
    expect(count(document, "#hide-viewed-toggle")).toBe(0);
    // The stored mark folds nothing.
    expect(isExpanded(cardOf(document, "story.txt"))).toBe(true);
    expect(isExpanded(cardOf(document, "notes.txt"))).toBe(true);
    // The tree lane carries no mark, and a right-click on the row opens no
    // menu (not even an empty one with its click-eating wash).
    expect(rowDecoration(document, "story.txt")).toBe("");
    expect(await openRowContextMenu(document, "story.txt")).toBeNull();
    expect(document.body.textContent).not.toContain("Mark as viewed");
    expect(treeShadow(document)?.querySelectorAll('[data-type="context-menu-wash"]')).toHaveLength(0);
  });
}

for (const [kind, source] of reviewSources) {
  test(`the ${kind} view keeps the Viewed marks: control, progress, filter, fold, and tree`, async () => {
    const { document } = await renderViewed(source);
    const story = cardOf(document, "story.txt");
    const notes = cardOf(document, "notes.txt");
    expect(story.querySelector(".file-review-viewed")?.getAttribute("aria-pressed")).toBe("true");
    expect(notes.querySelector(".file-review-viewed")?.getAttribute("aria-pressed")).toBe("false");
    expect(document.getElementById("files-viewed-progress")?.textContent).toBe("1 of 2 files viewed");
    expect(document.getElementById("hide-viewed-toggle")).toBeTruthy();
    // The stored mark folds its card.
    expect(isExpanded(story)).toBe(false);
    expect(isExpanded(notes)).toBe(true);
    expect(rowDecoration(document, "story.txt")).toBe("✓");
    expect(rowDecoration(document, "notes.txt")).toBe("");
    const menu = await openRowContextMenu(document, "notes.txt");
    expect(menu?.textContent ?? "").toContain("Mark as viewed");
    // The control's double-click is its own, not a fold of the card.
    expect(doubleClick(notes.querySelector(".file-review-viewed"))).toBe(false);
    expect(isExpanded(notes)).toBe(true);
  });
}

test("hide viewed, kept from a branch view, hides nothing in the working tree", async () => {
  const { document, requests, bridgeRequests } = await renderViewed(branchSource, PICKER_OPTIONS);
  click(document.getElementById("hide-viewed-toggle") as HTMLButtonElement);
  await waitFor(() => cards(document).length === 1, "the viewed file to hide");
  const select = document.getElementById("source-select") as HTMLSelectElement;
  select.value = "unstaged";
  flushSync(() => {
    select.dispatchEvent(new document.defaultView!.Event("change", { bubbles: true }));
  });
  await waitFor(() => requests.filter((request) => request.method === "sessionOpen").length === 2, "the unstaged session");
  await waitFor(() => cards(document).length === 2, "both files in the working tree", 3000);
  await waitForStoredMarks(document, bridgeRequests, "unstaged");
  expect(cards(document)).toHaveLength(2);
  expect(isExpanded(cardOf(document, "story.txt"))).toBe(true);
  expect(count(document, "#hide-viewed-toggle")).toBe(0);
  expect(count(document, "#files-viewed-progress")).toBe(0);
});
