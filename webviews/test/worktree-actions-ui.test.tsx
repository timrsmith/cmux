import { expect, test } from "bun:test";
import { flushSync } from "react-dom";
import { renderToStaticMarkup } from "react-dom/server";
import { App } from "../src/App";
import { createDiffViewerLabelResolver } from "../src/labels";
import { createDiffViewerStatus } from "../src/status";
import { FileWriteActions, HunkWriteActions } from "../src/WorktreeActions";
import { hunkVerbForSource, writeVerbsForSource } from "../src/worktree-actions";
import {
  click,
  emptyFetch,
  type FetchMock,
  findButton,
  mountDom,
  registerDomCleanup,
  render,
  rerender,
  resetDom,
  setTextareaValue,
  waitFor,
} from "./support/dom";
import {
  failureResponse,
  MOCK_CAPABILITY_TOKEN as token,
  MOCK_GITHUB_STATUS,
  MOCK_PULL_REQUEST,
  MOCK_REPOSITORY_STATUS,
  MOCK_SESSION_ID as sessionId,
  repositoryStatusResponse,
  sessionOpenedResponse,
  sidecarMock,
  type SidecarRequest,
} from "./support/sidecar-mock";

registerDomCleanup();

const label = createDiffViewerLabelResolver(undefined);
const viewerURL = `cmux-diff-viewer://${token}/viewer.html`;
const unstagedSource = { kind: "unstaged", repoRoot: "/tmp/repo" };
const stagedSource = { kind: "staged", repoRoot: "/tmp/repo" };

/** One modified file with one hunk (`@@ -1,3 +1,3 @@`), as the sidecar streams it. */
const ONE_FILE_PATCH = `diff --git a/story.txt b/story.txt
index 1111111..2222222 100644
--- a/story.txt
+++ b/story.txt
@@ -1,3 +1,3 @@
 one
-two
+two changed
 three
`;

const ONE_FILE_HUNK = {
  oldStart: 1,
  oldCount: 3,
  newStart: 1,
  newCount: 3,
};

/** `story.txt` followed by `notes.txt`, each with one hunk. */
const TWO_FILE_PATCH = `${ONE_FILE_PATCH}diff --git a/notes.txt b/notes.txt
index 3333333..4444444 100644
--- a/notes.txt
+++ b/notes.txt
@@ -1,2 +1,2 @@
 alpha
-beta
+beta changed
`;

/**
 * `story.txt` alone, with two hunks far enough apart to stay separate
 * (`@@ -1,3 +1,3 @@` and `@@ -20,3 +20,3 @@`); the only fixture that renders
 * hunk action rows, since a single-hunk file gets none.
 */
const TWO_HUNK_PATCH = `${ONE_FILE_PATCH}@@ -20,3 +20,3 @@
 twenty
-twenty-one
+twenty-one changed
 twenty-two
`;

/** The header ranges of `TWO_HUNK_PATCH`'s hunks, in order. */
const TWO_HUNK_HUNKS = [
  ONE_FILE_HUNK,
  { oldStart: 20, oldCount: 3, newStart: 20, newCount: 3 },
];

/** Source and repo options as the CLI sends them for a multi-repo view. */
const PICKER_OPTIONS = {
  sourceOptions: [
    { label: "Unstaged", value: "unstaged", sessionSource: unstagedSource },
    { label: "Staged", value: "staged", sessionSource: stagedSource },
    {
      label: "Last turn",
      value: "last-turn",
      sessionSource: { kind: "patch", path: "/last-turn.patch" },
    },
  ],
  repoOptions: [
    { label: "repo", value: "/tmp/repo", sessionSource: unstagedSource },
    {
      label: "other",
      value: "/tmp/other",
      sessionSource: { kind: "unstaged", repoRoot: "/tmp/other" },
    },
  ],
};

type RenderOptions = {
  /** Answers every patch fetch; by default the `patch` (or nothing). */
  fetch?: FetchMock;
  /** Adds to the page payload (picker options, for instance). */
  payloadExtras?: Record<string, unknown>;
  /** The diff every patch fetch streams; empty means an empty diff. */
  patch?: string;
};

/** Every patch fetch streams `patch`, or the empty diff for `""`. */
const patchFetch = (patch: string) =>
  patch === "" ? emptyFetch : () => new Response(patch, { status: 200 });

/**
 * Mounts the App on a typed WebKit session against `mock`. With a `patch`,
 * every patch fetch streams it and the render waits for its file header
 * actions; otherwise the diff is empty and the render waits for that.
 */
async function renderApp(
  source: any,
  mock: ReturnType<typeof sidecarMock>,
  { fetch, patch = "", payloadExtras = {} }: RenderOptions = {},
) {
  const dom = mountDom(viewerURL, fetch ?? patchFetch(patch));
  (dom.window as any).webkit = { messageHandlers: { cmuxDiff: mock } };
  render(
    <App
      config={{
        payload: {
          capabilityToken: token,
          pendingReplacement: true,
          sessionSource: source,
          statusMessage: "Loading diff",
          transport: {
            kind: "webKit",
            endpoint: "cmuxDiff",
            protocolVersion: 1,
          },
          ...payloadExtras,
        },
      }}
      initialStatus={createDiffViewerStatus("Loading diff", {
        loading: true,
        pending: true,
      })}
    />,
  );
  const document = dom.window.document;
  if (patch === "") {
    await waitFor(
      () => document.body.dataset.streamFileCount === "0",
      "the empty diff to stream",
    );
  } else {
    await waitFor(
      () => document.querySelectorAll(".worktree-action").length > 0,
      "the streamed file's header actions",
      3000,
    );
  }
  return document;
}

const requestsFor = (requests: SidecarRequest[], method: string) =>
  requests.filter((request) => request.method === method);

const sessionOpens = (requests: SidecarRequest[]) =>
  requestsFor(requests, "sessionOpen").length;

function headerAction(document: Document, action: string) {
  return document.querySelector<HTMLButtonElement>(`[data-action="${action}"]`);
}

/** Waits for the reopened session to stream the file's header actions again. */
async function waitForReload(document: Document, requests: SidecarRequest[]) {
  await waitFor(() => sessionOpens(requests) === 2, "the session to reopen");
  await waitFor(
    () =>
      document.querySelector<HTMLElement>(".worktree-file-actions")?.dataset
        .pending === "false",
    "the reloaded header actions to enable",
    3000,
  );
}

test("file header actions render per source kind and confirm before discarding", () => {
  const unstagedMarkup = renderToStaticMarkup(
    <FileWriteActions
      label={label}
      onAction={() => {}}
      pending={false}
      verbs={writeVerbsForSource(unstagedSource as any)}
    />,
  );
  expect(unstagedMarkup).toContain('data-action="stageFile"');
  expect(unstagedMarkup).toContain('data-action="discardFile"');
  expect(unstagedMarkup).not.toContain('data-action="unstageFile"');
  const stagedMarkup = renderToStaticMarkup(
    <FileWriteActions
      label={label}
      onAction={() => {}}
      pending={false}
      verbs={writeVerbsForSource(stagedSource as any)}
    />,
  );
  expect(stagedMarkup).toContain('data-action="unstageFile"');
  expect(stagedMarkup).not.toContain('data-action="stageFile"');
  // The Staged view only unstages: no Discard button, nothing to confirm.
  expect(stagedMarkup).not.toContain('data-action="discardFile"');
  expect(
    renderToStaticMarkup(
      <FileWriteActions
        label={label}
        onAction={() => {}}
        pending={false}
        verbs={[]}
      />,
    ),
  ).toBe("");

  const dom = mountDom();
  const actions: string[] = [];
  render(
    <FileWriteActions
      label={label}
      onAction={(verb) => actions.push(verb)}
      pending={false}
      verbs={writeVerbsForSource(unstagedSource as any)}
    />,
  );
  const document = dom.window.document;
  click(document.querySelector<HTMLButtonElement>('[data-action="stageFile"]'));
  expect(actions).toEqual(["stage"]);
  click(
    document.querySelector<HTMLButtonElement>('[data-action="discardFile"]'),
  );
  // Discard asks first; nothing has been sent yet.
  expect(actions).toEqual(["stage"]);
  expect(document.querySelector(".worktree-confirm-text")?.textContent).toBe(
    "Discard these changes?",
  );
  click(findButton(document, "Cancel"));
  expect(document.querySelector(".worktree-confirm")).toBeNull();
  click(
    document.querySelector<HTMLButtonElement>('[data-action="discardFile"]'),
  );
  click(findButton(document, "Discard"));
  expect(actions).toEqual(["stage", "discard"]);
});

test("header action cluster stops the header toggle but lets other keys reach the document", () => {
  const dom = mountDom();
  const seen: string[] = [];
  render(
    // oxlint-disable-next-line jsx-a11y/no-static-element-interactions
    <div onKeyDown={(event) => seen.push(event.key)}>
      <FileWriteActions
        label={label}
        onAction={() => {}}
        pending={false}
        verbs={writeVerbsForSource(unstagedSource as any)}
      />
    </div>,
  );
  const window = dom.window;
  const button = window.document.querySelector<HTMLButtonElement>(
    '[data-action="stageFile"]',
  )!;
  const press = (key: string, init: KeyboardEventInit = {}) =>
    button.dispatchEvent(
      new window.KeyboardEvent("keydown", { bubbles: true, key, ...init }),
    );
  press("Escape");
  press("f", { metaKey: true });
  press("Enter");
  press(" ");
  // Escape and Cmd+F bubble past the cluster; the header-activating keys
  // stop at it.
  expect(seen).toEqual(["Escape", "f"]);
});

test("hunk action row confirms a discard, unstages without asking, and disables while a write is pending", () => {
  const dom = mountDom();
  const discard = hunkVerbForSource(unstagedSource as any)!;
  const unstage = hunkVerbForSource(stagedSource as any)!;
  let actions = 0;
  render(
    <HunkWriteActions
      label={label}
      onAction={() => {
        actions += 1;
      }}
      pending={false}
      verb={discard}
    />,
  );
  const document = dom.window.document;
  expect(document.querySelector(".worktree-hunk-button span")?.textContent).toBe("Discard");
  click(document.querySelector<HTMLButtonElement>(".worktree-hunk-button"));
  expect(actions).toBe(0);
  click(findButton(document, "Discard"));
  expect(actions).toBe(1);
  rerender(<HunkWriteActions label={label} onAction={() => {}} pending verb={discard} />);
  expect(
    document.querySelector<HTMLButtonElement>(".worktree-hunk-button")
      ?.disabled,
  ).toBe(true);
  // The Staged view's row reads Unstage and acts at once: no confirmation,
  // no danger styling, since nothing it does touches the working tree.
  rerender(
    <HunkWriteActions
      label={label}
      onAction={() => {
        actions += 1;
      }}
      pending={false}
      verb={unstage}
    />,
  );
  expect(document.querySelector(".worktree-hunk-button span")?.textContent).toBe("Unstage");
  click(document.querySelector<HTMLButtonElement>(".worktree-hunk-button"));
  expect(actions).toBe(2);
  expect(document.querySelector(".worktree-confirm")).toBeNull();
  expect(document.querySelector(".worktree-confirm-danger")).toBeNull();
});

test("the header commit button renders for both working-tree views and never for branch or read-only sidecars", async () => {
  const cases: Array<{
    source: any;
    capabilities: string[];
    expected: "enabled" | "stageAll" | "absent";
  }> = [
    {
      source: stagedSource,
      capabilities: ["worktree.write"],
      expected: "enabled",
    },
    {
      source: unstagedSource,
      capabilities: ["worktree.write"],
      expected: "stageAll",
    },
    {
      source: { kind: "branch", repoRoot: "/tmp/repo", baseRef: "main" },
      capabilities: ["worktree.write"],
      expected: "absent",
    },
    {
      source: stagedSource,
      capabilities: ["transport.webkit"],
      expected: "absent",
    },
  ];
  for (const { source, capabilities, expected } of cases) {
    const requests: SidecarRequest[] = [];
    const document = await renderApp(
      source,
      sidecarMock(requests, capabilities),
    );
    await waitFor(
      () => requests.some((request) => request.method === "protocolHandshake"),
      "the handshake",
    );
    if (expected !== "absent") {
      await waitFor(
        () => Boolean(document.getElementById("commit-button")),
        "the commit button",
      );
    }
    // The view's "..." menu (the header's in working-tree views, the
    // toolbar's otherwise) renders after the handshake settled either way.
    await openOptionsMenu(document);
    const button = document.getElementById(
      "commit-button",
    ) as HTMLButtonElement | null;
    if (expected === "absent") {
      expect(button).toBeNull();
      expect(document.getElementById("repo-header")).toBeNull();
      // Read-only views never ask for the repository status.
      expect(requestsFor(requests, "worktreeRepositoryStatus")).toHaveLength(0);
    } else {
      expect(button).toBeTruthy();
      expect(button?.dataset.availability).toBe(expected);
      expect(button?.disabled).toBe(false);
      expect(document.getElementById("repo-header")).toBeTruthy();
    }
    await resetDom();
  }
});

test("committing sends the typed request with the open session and reopens the diff in place", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderApp(
    stagedSource,
    sidecarMock(requests, ["worktree.write"]),
  );
  await waitFor(
    () => Boolean(document.getElementById("commit-button")),
    "the commit button",
  );
  const commitButton = document.getElementById(
    "commit-button",
  ) as HTMLButtonElement;
  await waitFor(() => !commitButton.disabled, "the commit button to enable");
  click(commitButton);
  const textarea = document.querySelector<HTMLTextAreaElement>(
    ".commit-message-input",
  );
  expect(textarea).toBeTruthy();
  // An empty message never leaves the page.
  const submit = () => findButton(document, "Commit", "#commit-popover");
  expect(submit()?.disabled).toBe(true);
  click(submit());
  expect(requestsFor(requests, "worktreeCommit")).toHaveLength(0);
  setTextareaValue(textarea!, "  Ship it\n");
  await waitFor(
    () => submit()?.disabled === false,
    "the submit button to enable",
  );
  click(submit());
  await waitFor(
    () => requestsFor(requests, "worktreeCommit").length === 1,
    "the commit request",
  );
  const commit = requests.find(
    (request) => request.method === "worktreeCommit",
  );
  expect(commit?.params).toEqual({
    sessionId,
    capabilityToken: token,
    source: stagedSource,
    message: "Ship it",
  });
  // Success reopens the session in place (no page reload) and reports the hash.
  await waitFor(() => sessionOpens(requests) === 2, "the session to reopen");
  await waitFor(
    () =>
      document.getElementById("worktree-notice")?.textContent ===
      "Committed 0123456789",
    "the committed notice",
  );
  expect(document.getElementById("commit-popover")).toBeNull();
  expect(requestsFor(requests, "sessionOpen")[1].params.source).toEqual(
    stagedSource,
  );
});

test("a committed result without a commit hash still reloads and notifies", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderApp(
    stagedSource,
    sidecarMock(requests, ["worktree.write"], {
      worktreeCommit: (request) => ({
        id: request.id,
        version: 1,
        result: { type: "committed", value: {} },
        error: null,
      }),
    }),
  );
  const commitButton = document.getElementById(
    "commit-button",
  ) as HTMLButtonElement;
  await waitFor(() => !commitButton.disabled, "the commit button to enable");
  click(commitButton);
  setTextareaValue(
    document.querySelector<HTMLTextAreaElement>(".commit-message-input")!,
    "Ship it",
  );
  await waitFor(
    () => findButton(document, "Commit", "#commit-popover")?.disabled === false,
    "the submit button to enable",
  );
  click(findButton(document, "Commit", "#commit-popover"));
  await waitFor(() => sessionOpens(requests) === 2, "the session to reopen");
  await waitFor(
    () =>
      document.getElementById("worktree-notice")?.textContent === "Committed",
    "the committed notice without a hash",
  );
  expect(document.getElementById("worktree-notice")?.dataset.error).toBe(
    "false",
  );
});

test("an oversized commit message is flagged on submit and never sent", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderApp(
    stagedSource,
    sidecarMock(requests, ["worktree.write"]),
  );
  const commitButton = document.getElementById(
    "commit-button",
  ) as HTMLButtonElement;
  await waitFor(() => !commitButton.disabled, "the commit button to enable");
  click(commitButton);
  const textarea = document.querySelector<HTMLTextAreaElement>(
    ".commit-message-input",
  )!;
  setTextareaValue(textarea, "é".repeat((64 * 1024) / 2 + 1));
  const submit = () => findButton(document, "Commit", "#commit-popover");
  await waitFor(
    () => submit()?.disabled === false,
    "the submit button to enable",
  );
  expect(textarea.getAttribute("aria-invalid")).toBe("false");
  click(submit());
  expect(textarea.getAttribute("aria-invalid")).toBe("true");
  expect(document.querySelector(".commit-popover-hint")?.textContent).toBe(
    "Enter a commit message of at most 64 KiB.",
  );
  expect(submit()?.disabled).toBe(true);
  expect(requestsFor(requests, "worktreeCommit")).toHaveLength(0);
  // Editing clears the verdict until the next submit or blur.
  setTextareaValue(textarea, "short");
  await waitFor(
    () => submit()?.disabled === false,
    "the submit button to re-enable",
  );
  expect(textarea.getAttribute("aria-invalid")).toBe("false");
});

test("a failed write shows the localized sidecar error and keeps the session", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderApp(
    stagedSource,
    sidecarMock(requests, ["worktree.write"], {
      worktreeCommit: (request) =>
        failureResponse(
          request,
          "nothingToCommit",
          "There are no staged changes to commit",
        ),
    }),
  );
  await waitFor(
    () =>
      (document.getElementById("commit-button") as HTMLButtonElement | null)
        ?.disabled === false,
    "the commit button to enable",
  );
  click(document.getElementById("commit-button") as HTMLButtonElement);
  setTextareaValue(
    document.querySelector<HTMLTextAreaElement>(".commit-message-input")!,
    "Nothing",
  );
  await waitFor(
    () => findButton(document, "Commit", "#commit-popover")?.disabled === false,
    "the submit button to enable",
  );
  click(findButton(document, "Commit", "#commit-popover"));
  await waitFor(
    () =>
      document.getElementById("worktree-notice")?.textContent ===
      "Nothing to commit.",
    "the failure notice",
  );
  expect(document.getElementById("worktree-notice")?.dataset.error).toBe(
    "true",
  );
  expect(sessionOpens(requests)).toBe(1);
  // The failed write did not need a reload, so the actions are usable again.
  expect(
    (document.getElementById("commit-button") as HTMLButtonElement).disabled,
  ).toBe(false);
});

test("header Stage sends worktreeStageFiles for the streamed file and reopens the session", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderApp(
    unstagedSource,
    sidecarMock(requests, ["worktree.write"]),
    { patch: TWO_HUNK_PATCH },
  );
  // One row per hunk.
  expect(document.querySelectorAll(".worktree-hunk-button")).toHaveLength(2);
  click(headerAction(document, "stageFile"));
  await waitFor(
    () => requestsFor(requests, "worktreeStageFiles").length === 1,
    "the stage request",
  );
  expect(requestsFor(requests, "worktreeStageFiles")[0].params).toEqual({
    sessionId,
    capabilityToken: token,
    source: unstagedSource,
    paths: ["story.txt"],
  });
  await waitForReload(document, requests);
  expect(requestsFor(requests, "sessionOpen")[1].params.source).toEqual(
    unstagedSource,
  );
  // The reloaded file renders its actions again, header and hunk row alike.
  expect(headerAction(document, "stageFile")?.disabled).toBe(false);
  await waitFor(
    () => document.querySelectorAll(".worktree-hunk-button").length === 2,
    "the reloaded hunk rows",
  );
  expect(document.getElementById("worktree-notice")).toBeNull();
});

test("header Discard confirms first, then sends worktreeDiscardFiles", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderApp(
    unstagedSource,
    sidecarMock(requests, ["worktree.write"]),
    { patch: ONE_FILE_PATCH },
  );
  // A single-hunk file gets no hunk row: the header's Discard covers it.
  expect(document.querySelectorAll(".worktree-hunk-button")).toHaveLength(0);
  click(headerAction(document, "discardFile"));
  expect(requestsFor(requests, "worktreeDiscardFiles")).toHaveLength(0);
  expect(document.querySelector(".worktree-confirm-text")?.textContent).toBe(
    "Discard these changes?",
  );
  click(findButton(document, "Discard", ".worktree-file-actions"));
  await waitFor(
    () => requestsFor(requests, "worktreeDiscardFiles").length === 1,
    "the discard request",
  );
  expect(requestsFor(requests, "worktreeDiscardFiles")[0].params).toEqual({
    sessionId,
    capabilityToken: token,
    source: unstagedSource,
    paths: ["story.txt"],
  });
  await waitForReload(document, requests);
});

test("the files toggle points left to show the column and right to hide it", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(unstagedSource, MOCK_REPOSITORY_STATUS, requests);
  const toggle = () => document.querySelector<HTMLButtonElement>("#files-toggle")!;
  const glyph = () => toggle().querySelector("svg path")?.getAttribute("d") ?? "";
  expect(toggle().getAttribute("aria-pressed")).toBe("true");
  const hideGlyph = glyph();
  click(toggle());
  await waitFor(() => toggle().getAttribute("aria-pressed") === "false", "the column hidden");
  expect(glyph()).not.toBe(hideGlyph);
  // The arrow faces the way the column will move: hide points right, show points left.
  expect(hideGlyph.startsWith("M6.823")).toBe(true);
  expect(glyph().startsWith("m4.177")).toBe(true);
});

test("hunk row Discard (unstaged view) confirms first, then sends worktreeDiscardHunk with the hunk's header ranges", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderApp(
    unstagedSource,
    sidecarMock(requests, ["worktree.write"]),
    { patch: TWO_HUNK_PATCH },
  );
  const rows = document.querySelectorAll<HTMLButtonElement>(".worktree-hunk-button");
  expect(rows).toHaveLength(2);
  // The second row targets the second hunk, not the first.
  click(rows[1]);
  expect(requestsFor(requests, "worktreeDiscardHunk")).toHaveLength(0);
  // Only the clicked row confirms; the first row still offers its own
  // Discard, so the confirm button is the one inside the confirmation.
  expect(document.querySelectorAll(".worktree-confirm")).toHaveLength(1);
  click(findButton(document, "Discard", ".worktree-hunk-actions .worktree-confirm"));
  await waitFor(
    () => requestsFor(requests, "worktreeDiscardHunk").length === 1,
    "the hunk discard request",
  );
  expect(requestsFor(requests, "worktreeDiscardHunk")[0].params).toEqual({
    sessionId,
    capabilityToken: token,
    source: unstagedSource,
    path: "story.txt",
    hunk: TWO_HUNK_HUNKS[1],
  });
  await waitForReload(document, requests);
});

test("the Staged view's hunk row reads Unstage and sends worktreeUnstageHunk without asking; nothing there discards", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderApp(
    stagedSource,
    sidecarMock(requests, ["worktree.write"]),
    { patch: TWO_HUNK_PATCH },
  );
  const rows = document.querySelectorAll<HTMLButtonElement>(".worktree-hunk-button");
  expect(rows).toHaveLength(2);
  expect(Array.from(rows, (row) => row.querySelector("span")?.textContent)).toEqual(["Unstage", "Unstage"]);
  // The card offers Unstage alone: no Discard, so nothing to confirm.
  expect(headerAction(document, "unstageFile")).toBeTruthy();
  expect(headerAction(document, "discardFile")).toBeNull();
  click(rows[1]);
  expect(document.querySelector(".worktree-confirm")).toBeNull();
  await waitFor(
    () => requestsFor(requests, "worktreeUnstageHunk").length === 1,
    "the hunk unstage request",
  );
  expect(requestsFor(requests, "worktreeUnstageHunk")[0].params).toEqual({
    sessionId,
    capabilityToken: token,
    source: stagedSource,
    path: "story.txt",
    hunk: TWO_HUNK_HUNKS[1],
  });
  expect(requestsFor(requests, "worktreeDiscardHunk")).toHaveLength(0);
  await waitForReload(document, requests);
});

test("staleHunk and partialRevert show their notice and reopen the session", async () => {
  for (const [code, message, notice] of [
    [
      "staleHunk",
      "The hunk no longer matches the working tree",
      "This hunk changed on disk. The diff was reloaded.",
    ],
    [
      "partialRevert",
      "The change was unstaged but could not be removed from the working tree",
      "The change was unstaged but is still in the working tree. The diff was reloaded.",
    ],
  ]) {
    const requests: SidecarRequest[] = [];
    const document = await renderApp(
      unstagedSource,
      sidecarMock(requests, ["worktree.write"], {
        worktreeDiscardHunk: (request) =>
          failureResponse(request, code, message),
      }),
      { patch: TWO_HUNK_PATCH },
    );
    click(document.querySelector<HTMLButtonElement>(".worktree-hunk-button"));
    click(findButton(document, "Discard", ".worktree-hunk-actions"));
    await waitFor(
      () => document.getElementById("worktree-notice")?.textContent === notice,
      `the ${code} notice`,
    );
    expect(document.getElementById("worktree-notice")?.dataset.error).toBe(
      "true",
    );
    await waitForReload(document, requests);
    await resetDom();
  }
});

test("a second click while a write is pending is ignored, and the actions wait for the reopened session", async () => {
  const requests: SidecarRequest[] = [];
  let releaseWrite: (() => void) | undefined;
  let releaseReopen: (() => void) | undefined;
  const mock = sidecarMock(requests, ["worktree.write"], {
    worktreeUnstageFiles: async (request) => {
      await new Promise<void>((resolve) => {
        releaseWrite = resolve;
      });
      return {
        id: request.id,
        version: 1,
        result: {
          type: "worktreeMutated",
          value: { source: request.params.source },
        },
        error: null,
      };
    },
    sessionOpen: async (request) => {
      if (sessionOpens(requests) === 2) {
        await new Promise<void>((resolve) => {
          releaseReopen = resolve;
        });
      }
      return sessionOpenedResponse(request);
    },
  });
  const document = await renderApp(stagedSource, mock, { patch: TWO_HUNK_PATCH });
  const commitButton = document.getElementById(
    "commit-button",
  ) as HTMLButtonElement;
  await waitFor(() => !commitButton.disabled, "the commit button to enable");
  click(headerAction(document, "unstageFile"));
  await waitFor(
    () => requestsFor(requests, "worktreeUnstageFiles").length === 1,
    "the unstage request",
  );
  // While the write is in flight every action is disabled and a repeated
  // click sends nothing more.
  const cluster = document.querySelector<HTMLElement>(".worktree-file-actions");
  expect(cluster?.dataset.pending).toBe("true");
  expect(headerAction(document, "unstageFile")?.disabled).toBe(true);
  expect(
    document.querySelector<HTMLButtonElement>(".worktree-hunk-button")
      ?.disabled,
  ).toBe(true);
  expect(commitButton.disabled).toBe(true);
  headerAction(document, "unstageFile")?.click();
  expect(requestsFor(requests, "worktreeUnstageFiles")).toHaveLength(1);
  // The write finishes, but the reopened session has not answered yet: the
  // toolbar commit action (the one still rendered) stays disabled.
  releaseWrite?.();
  await waitFor(() => sessionOpens(requests) === 2, "the reopen request");
  await waitFor(
    () => document.querySelector(".worktree-file-actions") == null,
    "the old file to unmount for the reload",
  );
  expect(commitButton.disabled).toBe(true);
  releaseReopen?.();
  await waitFor(
    () => !commitButton.disabled,
    "the commit button to re-enable",
    3000,
  );
  await waitFor(
    () =>
      document.querySelector<HTMLElement>(".worktree-file-actions")?.dataset
        .pending === "false",
    "the reloaded header actions",
    3000,
  );
  expect(requestsFor(requests, "worktreeUnstageFiles")).toHaveLength(1);
});

/** Rendered code blocks across every file's shadow root; a collapsed file has none. */
function renderedCodeBlocks(document: Document): number {
  return Array.from(document.querySelectorAll("diffs-container")).reduce(
    (count, container) =>
      count + (container.shadowRoot?.querySelectorAll("pre").length ?? 0),
    0,
  );
}

test("collapse all keeps files collapsed through a write action reload", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderApp(
    unstagedSource,
    sidecarMock(requests, ["worktree.write"]),
    { patch: ONE_FILE_PATCH },
  );
  await waitFor(() => renderedCodeBlocks(document) === 1, "the file's code");
  await openOptionsMenu(document);
  click(findButton(document, "Collapse all diffs"));
  // A collapsed file keeps its header (and header actions) but renders no
  // code.
  await waitFor(() => renderedCodeBlocks(document) === 0, "the file to collapse");
  // Open in cmux, copy path, stage, discard.
  expect(document.querySelectorAll(".worktree-action")).toHaveLength(4);
  click(headerAction(document, "stageFile"));
  await waitForReload(document, requests);
  // The option survived the reset, so the re-streamed file arrives collapsed
  // (no per-item bookkeeping needed).
  expect(document.querySelectorAll(".worktree-action")).toHaveLength(4);
  expect(renderedCodeBlocks(document)).toBe(0);
  expect(document.body.dataset.streamFileCount).toBe("1");
  await openOptionsMenu(document);
  expect(findButton(document, "Expand all diffs")).toBeTruthy();
});

// MARK: Repository header, split button, pull requests, bulk actions

/**
 * Mounts a working-tree view whose status answers with `status`, streaming
 * `ONE_FILE_PATCH` unless the options say otherwise; `overrides` shape the
 * other sidecar answers.
 */
async function renderWithStatus(
  source: any,
  status: Record<string, unknown>,
  requests: SidecarRequest[],
  {
    overrides = {},
    patch = ONE_FILE_PATCH,
    ...options
  }: RenderOptions & {
    overrides?: Record<string, (request: SidecarRequest) => unknown>;
  } = {},
) {
  const document = await renderApp(
    source,
    sidecarMock(requests, ["worktree.write"], {
      worktreeRepositoryStatus: (request) => repositoryStatusResponse(request, status),
      ...overrides,
    }),
    { patch, ...options },
  );
  await waitFor(
    () => document.querySelector(".repo-header-branch") != null,
    "the status to render",
  );
  return document;
}

function setInputValue(input: HTMLInputElement, value: string): void {
  const window = input.ownerDocument.defaultView!;
  const descriptor = Object.getOwnPropertyDescriptor(
    window.HTMLInputElement.prototype,
    "value",
  );
  descriptor?.set?.call(input, value);
  flushSync(() => {
    input.dispatchEvent(new window.Event("focusin", { bubbles: true }));
    input.dispatchEvent(
      new window.KeyboardEvent("keyup", { bubbles: true, key: "t" }),
    );
  });
}

function menuAction(document: Document, action: string) {
  return document.querySelector<HTMLButtonElement>(
    `.repo-menu [data-action="${action}"]`,
  );
}

/** Opens the header's "..." menu unless it is open (a click would close it). */
function openOverflowMenu(document: Document): void {
  if (document.getElementById("repo-overflow-menu") == null) {
    click(document.getElementById("repo-overflow-button") as HTMLButtonElement);
  }
}

/** A batch action (whole view or selection) of the header's "..." menu, opened if needed. */
function headerBulkAction(document: Document, action: string) {
  openOverflowMenu(document);
  return document.querySelector<HTMLButtonElement>(
    `#repo-overflow-menu [data-action="${action}"]`,
  );
}

/** The "..." button's selection badge: the count it shows, or null while nothing is checked. */
function selectionBadge(document: Document): string | null {
  return document.getElementById("repo-overflow-button")?.getAttribute("data-selection-count") ?? null;
}

/** The card checkbox for `name` (`Select <name>`), never the header's select-all. */
function cardCheckbox(document: Document, name: string) {
  return document.querySelector<HTMLButtonElement>(`.file-select-toggle[aria-label="Select ${name}"]`);
}

function selectAllCheckbox(document: Document) {
  return document.getElementById("files-select-all") as HTMLButtonElement | null;
}

/** Toggles a checkbox the way a user does: one click; the state is its `aria-checked`. */
function toggleCheckbox(checkbox: HTMLButtonElement | null | undefined): void {
  expect(checkbox).toBeTruthy();
  flushSync(() => checkbox?.click());
}

/** The batch items of the "..." menu, in order: everything before its first separator. */
const headerBulkLabels = (document: Document) => {
  openOverflowMenu(document);
  const labels: string[] = [];
  for (const child of Array.from(document.getElementById("repo-overflow-menu")!.children)) {
    if (child.classList.contains("menu-separator")) {
      break;
    }
    labels.push(child.textContent?.trim() ?? "");
  }
  return labels;
};

test("the repository header shows the repo, branch, streamed totals, and upstream position", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(unstagedSource, MOCK_GITHUB_STATUS, requests);
  const header = document.getElementById("repo-header")!;
  expect(header.querySelector(".repo-header-repo")?.textContent).toBe("/tmp/repo");
  expect(header.querySelector(".repo-header-title")?.getAttribute("title")).toBe("/tmp/repo");
  expect(header.querySelector(".repo-header-branch")?.textContent).toBe("main");
  // The totals come from the streamed metrics: one file (singular), +1 / -1.
  expect(header.querySelector(".repo-header-files")?.textContent).toBe("1 file");
  expect(header.querySelector(".repo-header-additions")?.textContent).toBe("+1");
  expect(header.querySelector(".repo-header-deletions")?.textContent).toBe("-1");
  expect(header.querySelector(".repo-header-position")?.textContent).toBe("2 ahead");
  // One status query per opened view: no polling, and a write's reload (a
  // later session open of the same view) does not ask again.
  expect(requestsFor(requests, "worktreeRepositoryStatus")).toHaveLength(1);
  expect(requestsFor(requests, "worktreeRepositoryStatus")[0].params).toEqual({
    sessionId,
    capabilityToken: token,
    source: unstagedSource,
  });
  click(headerAction(document, "stageFile"));
  await waitForReload(document, requests);
  expect(sessionOpens(requests)).toBe(2);
  expect(requestsFor(requests, "worktreeRepositoryStatus")).toHaveLength(1);
});

test("the header shows the host's ~-abbreviated repository label from the payload", async () => {
  // The CLI knows the real home directory; here it is one the page could not
  // guess from the path's shape.
  const requests: SidecarRequest[] = [];
  const homeSource = { kind: "unstaged", repoRoot: "/srv/home/dev/widgets" };
  const document = await renderWithStatus(homeSource, MOCK_REPOSITORY_STATUS, requests, {
    payloadExtras: { repoRoot: "/srv/home/dev/widgets", repoLabel: "~/widgets" },
  });
  expect(document.querySelector(".repo-header-repo")?.textContent).toBe("~/widgets");
  expect(document.querySelector(".repo-header-title")?.getAttribute("title")).toBe(
    "/srv/home/dev/widgets",
  );
});

test("an older page without a repository label abbreviates a home-directory path itself", async () => {
  const requests: SidecarRequest[] = [];
  const homeSource = { kind: "unstaged", repoRoot: "/Users/dev/src/widgets" };
  const document = await renderWithStatus(homeSource, MOCK_REPOSITORY_STATUS, requests);
  expect(document.querySelector(".repo-header-repo")?.textContent).toBe("~/src/widgets");
  expect(document.querySelector(".repo-header-title")?.getAttribute("title")).toBe(
    "/Users/dev/src/widgets",
  );
});

test("the split button offers push and create PR/MR according to the host kind and forge CLI", async () => {
  const cases: Array<{
    status: Record<string, unknown>;
    push: boolean;
    create: boolean;
    createLabel: string;
    createHint?: string;
    pushHint?: string;
  }> = [
    {
      status: MOCK_REPOSITORY_STATUS,
      push: true,
      create: false,
      createLabel: "Create PR",
      createHint: "Not available for this remote.",
    },
    {
      status: MOCK_GITHUB_STATUS,
      push: true,
      create: true,
      createLabel: "Create PR",
    },
    {
      status: {
        ...MOCK_GITHUB_STATUS,
        hostKind: "gitlab",
        forgeCli: { available: true, authenticated: false },
      },
      push: true,
      create: false,
      createLabel: "Create MR",
      createHint: "Sign in with gh auth login or glab auth login, then try again.",
    },
    {
      status: {
        ...MOCK_GITHUB_STATUS,
        forgeCli: { available: false, authenticated: false },
      },
      push: true,
      create: false,
      createLabel: "Create PR",
      createHint: "Install the GitHub CLI (gh) or GitLab CLI (glab) to use this action.",
    },
    {
      status: { ...MOCK_REPOSITORY_STATUS, upstream: undefined, hostKind: "none" },
      push: false,
      create: false,
      createLabel: "Create PR",
      pushHint: "The repository has no remote.",
      createHint: "The repository has no remote.",
    },
  ];
  for (const testCase of cases) {
    const requests: SidecarRequest[] = [];
    const document = await renderWithStatus(stagedSource, testCase.status, requests);
    click(document.getElementById("commit-menu-button") as HTMLButtonElement);
    const push = menuAction(document, "push")!;
    const create = menuAction(document, "createPullRequest")!;
    expect(push.disabled).toBe(!testCase.push);
    expect(create.disabled).toBe(!testCase.create);
    expect(create.textContent).toBe(testCase.createLabel);
    expect(create.getAttribute("title") ?? undefined).toBe(testCase.createHint);
    expect(push.getAttribute("title") ?? undefined).toBe(testCase.pushHint);
    // Escape closes the menu without sending anything.
    document.dispatchEvent(
      new (document.defaultView as any).KeyboardEvent("keydown", { key: "Escape", bubbles: true }),
    );
    await waitFor(() => document.getElementById("commit-menu") == null, "the menu to close");
    expect(requestsFor(requests, "worktreePush")).toHaveLength(0);
    await resetDom();
  }
});

test("the pull request card renders the status' request and links to it externally", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(
    stagedSource,
    { ...MOCK_GITHUB_STATUS, pullRequest: MOCK_PULL_REQUEST },
    requests,
  );
  const card = document.getElementById("pull-request-card")!;
  expect(card.querySelector(".pull-request-number")?.textContent).toBe("#42");
  expect(card.querySelector(".pull-request-state")?.textContent).toBe("Draft");
  expect(card.querySelector(".pull-request-title")?.textContent).toBe("Add widgets");
  expect(card.querySelector(".pull-request-base")?.textContent).toBe("into main");
  expect(card.querySelector(".pull-request-checks")?.textContent).toBe(
    "2/3 checks passed · 1 pending",
  );
  expect(card.querySelector(".pull-request-review")?.textContent).toBe("Review required");
  const link = card.querySelector<HTMLAnchorElement>("a.pull-request-link")!;
  expect(link.getAttribute("href")).toBe("https://github.com/acme/widgets/pull/42");
  expect(link.getAttribute("target")).toBe("_blank");
  expect(link.getAttribute("rel")).toBe("noreferrer");
  expect(link.getAttribute("aria-label")).toBe("Open pull request");
  await resetDom();

  // A merged request on GitLab, with a non-web URL: state badge, MR wording,
  // and no link the viewer could navigate to.
  const gitlabRequests: SidecarRequest[] = [];
  const gitlabDocument = await renderWithStatus(
    stagedSource,
    {
      ...MOCK_GITHUB_STATUS,
      hostKind: "gitlab",
      forgeCli: { available: true, authenticated: true },
      pullRequest: {
        ...MOCK_PULL_REQUEST,
        state: "merged",
        isDraft: false,
        url: "javascript:alert(1)",
        checks: undefined,
        reviewDecision: undefined,
      },
    },
    gitlabRequests,
  );
  const gitlabCard = gitlabDocument.getElementById("pull-request-card")!;
  expect(gitlabCard.querySelector(".pull-request-state")?.textContent).toBe("Merged");
  expect(gitlabCard.getAttribute("aria-label")).toBe("Open merge request");
  expect(gitlabCard.querySelector("a")).toBeNull();
  expect(gitlabCard.querySelector(".pull-request-checks")).toBeNull();
});

test("the header's menu leads with the view's batch actions, and the header row carries none", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(unstagedSource, MOCK_REPOSITORY_STATUS, requests);
  // Nothing checked: no count on the "..." button, and no action buttons in
  // the header row itself besides Commit.
  expect(selectionBadge(document)).toBeNull();
  expect(document.getElementById("repo-overflow-button")?.getAttribute("aria-label")).toBe("More actions");
  expect(document.querySelectorAll("#repo-header .repo-header-actions [data-action]")).toHaveLength(0);
  // Unstaged: Stage all and Discard all changes… (the danger item), icon plus
  // text, enabled while no write is pending, ahead of the view options.
  expect(headerBulkLabels(document)).toEqual(["Stage all", "Discard all changes…"]);
  expect(headerBulkAction(document, "unstageAll")).toBeNull();
  expect(headerBulkAction(document, "discardAll")?.dataset.danger).toBe("true");
  expect(headerBulkAction(document, "stageAll")?.dataset.danger).toBeUndefined();
  expect(headerBulkAction(document, "stageAll")?.querySelector("svg")).toBeTruthy();
  expect(headerBulkAction(document, "stageAll")?.disabled).toBe(false);
  expect(menuAction(document, "refresh")).toBeTruthy();
  click(document.getElementById("repo-overflow-button") as HTMLButtonElement);
  expect(document.getElementById("repo-overflow-menu")).toBeNull();
  expect(sessionOpens(requests)).toBe(1);
});

test("discard all confirms in a header popover and posts worktreeDiscardAll exactly once", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(unstagedSource, MOCK_REPOSITORY_STATUS, requests);
  click(headerBulkAction(document, "discardAll"));
  // Asking is not doing: nothing has been sent; the menu closed and the
  // prompt is shown in its place.
  expect(requestsFor(requests, "worktreeDiscardAll")).toHaveLength(0);
  expect(document.getElementById("repo-overflow-menu")).toBeNull();
  expect(document.querySelector("#discard-popover .worktree-confirm-text")?.textContent).toBe(
    "Discard every change in this view? This cannot be undone.",
  );
  // Cancel closes the popover and sends nothing.
  click(document.querySelector<HTMLButtonElement>('#discard-popover [data-action="cancel"]'));
  expect(document.getElementById("discard-popover")).toBeNull();
  expect(requestsFor(requests, "worktreeDiscardAll")).toHaveLength(0);
  click(headerBulkAction(document, "discardAll"));
  const confirm = document.querySelector<HTMLButtonElement>('#discard-popover [data-action="confirm"]')!;
  expect(confirm.textContent).toBe("Discard all");
  expect(confirm.className).toContain("worktree-confirm-danger");
  click(confirm);
  // A second click on the (now unmounted) confirm cannot post again.
  confirm.click();
  await waitFor(
    () => requestsFor(requests, "worktreeDiscardAll").length === 1,
    "the discard-all request",
  );
  expect(requestsFor(requests, "worktreeDiscardAll")[0].params).toEqual({
    sessionId,
    capabilityToken: token,
    source: unstagedSource,
  });
  expect(document.getElementById("discard-popover")).toBeNull();
  await waitForReload(document, requests);
  expect(requestsFor(requests, "worktreeDiscardAll")).toHaveLength(1);
});

test("a failed discard all reloads the diff: Git may have restored some paths before giving up", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(unstagedSource, MOCK_REPOSITORY_STATUS, requests, {
    overrides: {
      worktreeDiscardAll: (request) =>
        failureResponse(request, "worktreeWriteFailed", "Could not update the working tree", true),
    },
  });
  click(headerBulkAction(document, "discardAll"));
  click(document.querySelector<HTMLButtonElement>('#discard-popover [data-action="confirm"]'));
  await waitFor(
    () => requestsFor(requests, "worktreeDiscardAll").length === 1,
    "the discard-all request",
  );
  await waitFor(
    () =>
      document.getElementById("worktree-notice")?.textContent ===
      "Could not update the working tree.",
    "the failure notice",
  );
  expect(document.getElementById("worktree-notice")?.dataset.error).toBe("true");
  // Unlike a single-file failure (which keeps the session), the bulk failure
  // reopens it so the page shows whatever Git left behind.
  await waitForReload(document, requests);
  expect(requestsFor(requests, "worktreeDiscardAll")).toHaveLength(1);
});

test("stage all and unstage all post their session command and reopen the diff", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(stagedSource, MOCK_REPOSITORY_STATUS, requests);
  // Staged: Unstage all alone; never Stage all, and never Discard (nothing
  // in this view touches the working tree), so no danger item either.
  expect(headerBulkLabels(document)).toEqual(["Unstage all"]);
  expect(headerBulkAction(document, "stageAll")).toBeNull();
  expect(headerBulkAction(document, "discardAll")).toBeNull();
  expect(document.querySelector('#repo-overflow-menu [data-danger="true"]')).toBeNull();
  click(headerBulkAction(document, "unstageAll"));
  await waitFor(
    () => requestsFor(requests, "worktreeUnstageAll").length === 1,
    "the unstage-all request",
  );
  expect(requestsFor(requests, "worktreeUnstageAll")[0].params).toEqual({
    sessionId,
    capabilityToken: token,
    source: stagedSource,
  });
  await waitForReload(document, requests);
  // Unstaged: Stage all posts its command the same way.
  const unstagedRequests: SidecarRequest[] = [];
  const unstagedDocument = await renderWithStatus(unstagedSource, MOCK_REPOSITORY_STATUS, unstagedRequests);
  click(headerBulkAction(unstagedDocument, "stageAll"));
  await waitFor(
    () => requestsFor(unstagedRequests, "worktreeStageAll").length === 1,
    "the stage-all request",
  );
  expect(requestsFor(unstagedRequests, "worktreeStageAll")[0].params).toEqual({
    sessionId,
    capabilityToken: token,
    source: unstagedSource,
  });
  await waitForReload(unstagedDocument, unstagedRequests);
});

test("checking a file card switches the header to the selection and stages exactly those paths", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(
    unstagedSource,
    MOCK_REPOSITORY_STATUS,
    requests,
    { patch: TWO_FILE_PATCH },
  );
  await waitFor(() => cardCheckbox(document, "notes.txt") != null, "both cards");
  const story = cardCheckbox(document, "story.txt")!;
  const notes = cardCheckbox(document, "notes.txt")!;
  const selectAll = selectAllCheckbox(document)!;
  // Checkbox semantics on the app's standard icon button.
  expect(story.getAttribute("role")).toBe("checkbox");
  expect(story.getAttribute("aria-checked")).toBe("false");
  expect(selectAll.getAttribute("role")).toBe("checkbox");
  expect(selectAll.getAttribute("aria-checked")).toBe("false");
  expect(selectAll.disabled).toBe(false);
  // The card header reads [fold caret][checkbox][path]: the checkbox took
  // the slot of the library's file-type icon, right after the caret.
  expect(story.previousElementSibling?.classList.contains("file-collapse-toggle")).toBe(true);
  expect(selectionBadge(document)).toBeNull();
  expect(headerBulkLabels(document)).toEqual(["Stage all", "Discard all changes…"]);

  // One file checked: the menu names the selection (singular) and offers to
  // clear it, the "..." button wears the count, and the select-all is
  // indeterminate.
  toggleCheckbox(story);
  await waitFor(() => headerBulkAction(document, "stageFiles") != null, "the selection actions");
  expect(headerBulkLabels(document)).toEqual(["Stage 1 file", "Discard 1 file…", "Clear selection"]);
  expect(headerBulkAction(document, "stageAll")).toBeNull();
  expect(selectionBadge(document)).toBe("1");
  expect(document.getElementById("repo-overflow-button")?.getAttribute("aria-label")).toBe(
    "More actions (1 selected)",
  );
  expect(cardCheckbox(document, "story.txt")?.getAttribute("aria-checked")).toBe("true");
  expect(cardCheckbox(document, "notes.txt")?.getAttribute("aria-checked")).toBe("false");
  expect(selectAllCheckbox(document)?.getAttribute("aria-checked")).toBe("mixed");

  // Both: plural, select-all checked. Unchecking one goes back to the singular.
  toggleCheckbox(notes);
  await waitFor(
    () => headerBulkAction(document, "stageFiles")?.textContent?.trim() === "Stage 2 files",
    "two files selected",
  );
  expect(selectionBadge(document)).toBe("2");
  expect(selectAllCheckbox(document)?.getAttribute("aria-checked")).toBe("true");
  expect(selectAllCheckbox(document)?.getAttribute("aria-checked")).not.toBe("mixed");
  toggleCheckbox(cardCheckbox(document, "notes.txt"));
  await waitFor(
    () => headerBulkAction(document, "stageFiles")?.textContent?.trim() === "Stage 1 file",
    "one file selected again",
  );

  // Stage the selection: one request naming exactly the checked path.
  click(headerBulkAction(document, "stageFiles"));
  await waitFor(() => requestsFor(requests, "worktreeStageFiles").length === 1, "the stage-files request");
  expect(requestsFor(requests, "worktreeStageFiles")[0].params).toEqual({
    sessionId,
    capabilityToken: token,
    source: unstagedSource,
    paths: ["story.txt"],
  });
  await waitForReload(document, requests);
  // The mock streams the same two files back, so story.txt is still in the
  // view: a path that survives a reload stays checked.
  await waitFor(() => cardCheckbox(document, "story.txt") != null, "the reloaded cards");
  expect(cardCheckbox(document, "story.txt")?.getAttribute("aria-checked")).toBe("true");
  expect(headerBulkLabels(document)).toEqual(["Stage 1 file", "Discard 1 file…", "Clear selection"]);
  // Per-file buttons keep working alongside the selection: the same list
  // request, naming that card's file only.
  click(headerAction(document, "stageFile"));
  await waitFor(() => requestsFor(requests, "worktreeStageFiles").length === 2, "the per-file stage request");
  expect(requestsFor(requests, "worktreeStageFiles")[1].params.paths).toEqual(["story.txt"]);
});

test("a reload that drops a checked file drops it from the selection", async () => {
  const requests: SidecarRequest[] = [];
  // First stream: two files. After the write, the sidecar's diff has only one.
  let fetches = 0;
  const document = await renderWithStatus(
    unstagedSource,
    MOCK_REPOSITORY_STATUS,
    requests,
    {
      fetch: () => {
        fetches += 1;
        return new Response(fetches === 1 ? TWO_FILE_PATCH : ONE_FILE_PATCH, { status: 200 });
      },
    },
  );
  await waitFor(() => cardCheckbox(document, "notes.txt") != null, "both cards");
  toggleCheckbox(cardCheckbox(document, "notes.txt"));
  await waitFor(
    () => headerBulkAction(document, "stageFiles")?.textContent?.trim() === "Stage 1 file",
    "notes.txt selected",
  );
  click(headerBulkAction(document, "stageFiles"));
  await waitFor(() => requestsFor(requests, "worktreeStageFiles").length === 1, "the stage-files request");
  expect(requestsFor(requests, "worktreeStageFiles")[0].params.paths).toEqual(["notes.txt"]);
  await waitForReload(document, requests);
  // notes.txt left the view, and with it the selection: the whole-view
  // actions are back, the badge is gone and nothing is checked.
  await waitFor(() => headerBulkAction(document, "stageAll") != null, "the whole-view actions");
  expect(selectionBadge(document)).toBeNull();
  expect(cardCheckbox(document, "notes.txt")).toBeNull();
  expect(cardCheckbox(document, "story.txt")?.getAttribute("aria-checked")).toBe("false");
  expect(selectAllCheckbox(document)?.getAttribute("aria-checked")).toBe("false");
  expect(selectAllCheckbox(document)?.getAttribute("aria-checked")).not.toBe("mixed");
});

test("select all checks every listed file, toggles back to none, and discard selected confirms before posting worktreeDiscardFiles", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(
    unstagedSource,
    MOCK_REPOSITORY_STATUS,
    requests,
    { patch: TWO_FILE_PATCH },
  );
  await waitFor(() => cardCheckbox(document, "notes.txt") != null, "both cards");
  toggleCheckbox(selectAllCheckbox(document));
  await waitFor(
    () => headerBulkAction(document, "stageFiles")?.textContent?.trim() === "Stage 2 files",
    "both files selected",
  );
  expect(headerBulkLabels(document)).toEqual(["Stage 2 files", "Discard 2 files…", "Clear selection"]);
  expect(cardCheckbox(document, "story.txt")?.getAttribute("aria-checked")).toBe("true");
  expect(cardCheckbox(document, "notes.txt")?.getAttribute("aria-checked")).toBe("true");
  // Checked select-all clears; from indeterminate it clears too.
  toggleCheckbox(selectAllCheckbox(document));
  await waitFor(() => headerBulkAction(document, "stageAll") != null, "nothing selected");
  expect(cardCheckbox(document, "story.txt")?.getAttribute("aria-checked")).toBe("false");
  toggleCheckbox(cardCheckbox(document, "story.txt"));
  await waitFor(() => selectAllCheckbox(document)?.getAttribute("aria-checked") === "mixed", "indeterminate");
  toggleCheckbox(selectAllCheckbox(document));
  await waitFor(() => headerBulkAction(document, "stageAll") != null, "cleared from indeterminate");
  // Select all again and discard the selection: the prompt names the
  // selection, the confirm too; the request carries both paths in diff order.
  toggleCheckbox(selectAllCheckbox(document));
  await waitFor(() => headerBulkAction(document, "discardFiles") != null, "the selection actions");
  click(headerBulkAction(document, "discardFiles"));
  expect(requestsFor(requests, "worktreeDiscardFiles")).toHaveLength(0);
  expect(document.querySelector("#discard-popover .worktree-confirm-text")?.textContent).toBe(
    "Discard every change to the selected files? This cannot be undone.",
  );
  const confirm = document.querySelector<HTMLButtonElement>('#discard-popover [data-action="confirm"]')!;
  expect(confirm.textContent).toBe("Discard selected");
  click(confirm);
  await waitFor(
    () => requestsFor(requests, "worktreeDiscardFiles").length === 1,
    "the discard-files request",
  );
  expect(requestsFor(requests, "worktreeDiscardFiles")[0].params).toEqual({
    sessionId,
    capabilityToken: token,
    source: unstagedSource,
    paths: ["story.txt", "notes.txt"],
  });
  expect(document.getElementById("discard-popover")).toBeNull();
  await waitForReload(document, requests);
  // Clear selection returns to the whole-view actions, drops the badge and
  // unchecks the cards.
  await waitFor(() => headerBulkAction(document, "clearSelection") != null, "the selection after reload");
  expect(selectionBadge(document)).toBe("2");
  click(headerBulkAction(document, "clearSelection"));
  await waitFor(() => headerBulkAction(document, "stageAll") != null, "the whole-view actions");
  expect(selectionBadge(document)).toBeNull();
  expect(cardCheckbox(document, "story.txt")?.getAttribute("aria-checked")).toBe("false");
  expect(cardCheckbox(document, "notes.txt")?.getAttribute("aria-checked")).toBe("false");
  expect(requestsFor(requests, "worktreeDiscardFiles")).toHaveLength(1);
});

test("the Staged view's selection offers Unstage N files and Clear selection only, and unstages without asking", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(
    stagedSource,
    MOCK_REPOSITORY_STATUS,
    requests,
    { patch: TWO_FILE_PATCH },
  );
  await waitFor(() => cardCheckbox(document, "notes.txt") != null, "both cards");
  toggleCheckbox(selectAllCheckbox(document));
  await waitFor(
    () => headerBulkAction(document, "unstageFiles")?.textContent?.trim() === "Unstage 2 files",
    "both files selected",
  );
  expect(headerBulkLabels(document)).toEqual(["Unstage 2 files", "Clear selection"]);
  expect(headerBulkAction(document, "discardFiles")).toBeNull();
  expect(document.querySelector('#repo-overflow-menu [data-danger="true"]')).toBeNull();
  click(headerBulkAction(document, "unstageFiles"));
  // No confirmation popover: the request is on its way.
  expect(document.getElementById("discard-popover")).toBeNull();
  await waitFor(
    () => requestsFor(requests, "worktreeUnstageFiles").length === 1,
    "the unstage-files request",
  );
  expect(requestsFor(requests, "worktreeUnstageFiles")[0].params).toEqual({
    sessionId,
    capabilityToken: token,
    source: stagedSource,
    paths: ["story.txt", "notes.txt"],
  });
  expect(requestsFor(requests, "worktreeDiscardFiles")).toHaveLength(0);
  await waitForReload(document, requests);
});

/** A file row of the file list, inside the tree's shadow root. */
function treeRow(document: Document, name: string): HTMLElement {
  const shadow = document.querySelector("file-tree-container")?.shadowRoot ?? null;
  expect(shadow).toBeTruthy();
  const row = shadow!.querySelector<HTMLElement>(`[data-item-type="file"][data-item-path="${name}"]`);
  expect(row).toBeTruthy();
  return row!;
}

/** Space on a row: the keyboard toggle of its checkbox, which fires no mousedown. */
function pressSpaceOn(row: HTMLElement): void {
  const window = row.ownerDocument.defaultView!;
  flushSync(() => {
    row.dispatchEvent(
      new window.KeyboardEvent("keydown", { key: " ", bubbles: true, composed: true, cancelable: true }),
    );
  });
}

/** Checks `name` alone and opens the selection-scoped discard confirmation; returns its Confirm. */
async function openDiscardSelectedConfirmation(document: Document, name: string): Promise<HTMLButtonElement> {
  await waitFor(() => cardCheckbox(document, name) != null, "the cards");
  toggleCheckbox(cardCheckbox(document, name));
  await waitFor(() => headerBulkAction(document, "discardFiles") != null, "the selection actions");
  click(headerBulkAction(document, "discardFiles"));
  expect(document.querySelector("#discard-popover .worktree-confirm-text")?.textContent).toBe(
    "Discard every change to the selected files? This cannot be undone.",
  );
  const confirm = document.querySelector<HTMLButtonElement>('#discard-popover [data-action="confirm"]');
  expect(confirm?.textContent).toBe("Discard selected");
  return confirm!;
}

test("the discard confirmation keeps the scope it opened with: an emptied selection closes it instead of discarding everything", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(
    unstagedSource,
    MOCK_REPOSITORY_STATUS,
    requests,
    { patch: TWO_FILE_PATCH },
  );
  const confirm = await openDiscardSelectedConfirmation(document, "notes.txt");
  // Space on the tree row unchecks the file. No mousedown happens, so the
  // outside-click dismissal never sees it: the header itself must notice
  // that the selection it asked about is gone, and not fall back to "all".
  pressSpaceOn(treeRow(document, "notes.txt"));
  await waitFor(() => selectionBadge(document) == null, "nothing selected");
  // Confirm posts nothing, whether it is still mounted for the frame before
  // the popover closes or already gone.
  confirm.click();
  expect(requestsFor(requests, "worktreeDiscardAll")).toHaveLength(0);
  expect(requestsFor(requests, "worktreeDiscardFiles")).toHaveLength(0);
  await waitFor(() => document.getElementById("discard-popover") == null, "the confirmation to close");
  confirm.click();
  expect(requestsFor(requests, "worktreeDiscardAll")).toHaveLength(0);
  expect(requestsFor(requests, "worktreeDiscardFiles")).toHaveLength(0);
  expect(sessionOpens(requests)).toBe(1);
});

test("a host refresh while the discard confirmation is open closes it", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(
    unstagedSource,
    MOCK_REPOSITORY_STATUS,
    requests,
    { patch: TWO_FILE_PATCH },
  );
  await openDiscardSelectedConfirmation(document, "notes.txt");
  // The host reloads the diff under the popover: what it asked about was
  // the view before the reload, so it closes rather than confirming later.
  expect(document.defaultView!.cmuxDiffViewer?.refresh()).toBe(true);
  await waitFor(() => document.getElementById("discard-popover") == null, "the confirmation to close");
  await waitForReload(document, requests);
  expect(document.getElementById("discard-popover")).toBeNull();
  expect(requestsFor(requests, "worktreeDiscardFiles")).toHaveLength(0);
  expect(requestsFor(requests, "worktreeDiscardAll")).toHaveLength(0);
});

test("a write's reload keeps the batch actions disabled until the reopened diff has streamed, then shows the full count", async () => {
  const requests: SidecarRequest[] = [];
  let fetches = 0;
  let releaseReloadedPatch: (() => void) | undefined;
  const document = await renderWithStatus(
    unstagedSource,
    MOCK_REPOSITORY_STATUS,
    requests,
    {
      // The reopened session's patch is held until the test releases it.
      fetch: () => {
        fetches += 1;
        if (fetches === 1) {
          return new Response(TWO_FILE_PATCH, { status: 200 });
        }
        return new Promise<Response>((resolve) => {
          releaseReloadedPatch = () => resolve(new Response(TWO_FILE_PATCH, { status: 200 }));
        });
      },
    },
  );
  await waitFor(() => cardCheckbox(document, "notes.txt") != null, "both cards");
  toggleCheckbox(selectAllCheckbox(document));
  await waitFor(
    () => headerBulkAction(document, "stageFiles")?.textContent?.trim() === "Stage 2 files",
    "both files selected",
  );
  click(headerBulkAction(document, "stageFiles"));
  await waitFor(() => requestsFor(requests, "worktreeStageFiles").length === 1, "the stage request");
  // The session reopened and its stream is being parsed, but no file has
  // arrived yet: an action now would act on whatever subset had streamed.
  await waitFor(
    () =>
      sessionOpens(requests) === 2 &&
      document.getElementById("status-text")?.textContent === "Parsing diff...",
    "the reopened session to start streaming",
  );
  expect(fetches).toBe(2);
  const commitButton = document.getElementById("commit-button") as HTMLButtonElement;
  expect(commitButton.disabled).toBe(true);
  const batchActions = () =>
    Array.from(
      document.querySelectorAll<HTMLButtonElement>(
        '#repo-overflow-menu [data-action$="All"], #repo-overflow-menu [data-action$="Files"]',
      ),
    );
  openOverflowMenu(document);
  expect(batchActions().length).toBeGreaterThan(0);
  expect(batchActions().map((action) => action.disabled)).toEqual(batchActions().map(() => true));
  // The stream completes: both files are back, still checked, and the
  // actions re-enable naming all of them.
  releaseReloadedPatch?.();
  await waitFor(
    () =>
      headerBulkAction(document, "stageFiles")?.textContent?.trim() === "Stage 2 files" &&
      headerBulkAction(document, "stageFiles")?.disabled === false,
    "the full selection, enabled",
    3000,
  );
  expect(commitButton.disabled).toBe(false);
  expect(requestsFor(requests, "worktreeStageFiles")).toHaveLength(1);
});

test("a reload that streams no files clears the selection, so nothing comes back pre-checked", async () => {
  const requests: SidecarRequest[] = [];
  // First stream: two files. After the write the view is empty; the host
  // refresh after that lists both files again.
  let fetches = 0;
  const document = await renderWithStatus(
    unstagedSource,
    MOCK_REPOSITORY_STATUS,
    requests,
    {
      fetch: () => {
        fetches += 1;
        return new Response(fetches === 2 ? "" : TWO_FILE_PATCH, { status: 200 });
      },
    },
  );
  await waitFor(() => cardCheckbox(document, "notes.txt") != null, "both cards");
  toggleCheckbox(cardCheckbox(document, "story.txt"));
  await waitFor(
    () => headerBulkAction(document, "stageFiles")?.textContent?.trim() === "Stage 1 file",
    "story.txt selected",
  );
  click(headerBulkAction(document, "stageFiles"));
  await waitFor(() => requestsFor(requests, "worktreeStageFiles").length === 1, "the stage request");
  const commitButton = document.getElementById("commit-button") as HTMLButtonElement;
  await waitFor(
    () =>
      sessionOpens(requests) === 2 &&
      document.body.dataset.streamFileCount === "0" &&
      !commitButton.disabled,
    "the empty reload to settle",
    3000,
  );
  expect(selectionBadge(document)).toBeNull();
  // The next reload lists story.txt again: it had left the view, so it
  // comes back unchecked.
  expect(document.defaultView!.cmuxDiffViewer?.refresh()).toBe(true);
  await waitFor(() => sessionOpens(requests) === 3, "the third session");
  await waitFor(
    () => cardCheckbox(document, "notes.txt") != null && !commitButton.disabled,
    "the files back in the view",
    3000,
  );
  expect(cardCheckbox(document, "story.txt")?.getAttribute("aria-checked")).toBe("false");
  expect(selectionBadge(document)).toBeNull();
  expect(headerBulkAction(document, "stageAll")).not.toBeNull();
});

test("switching the view clears the selection", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(
    unstagedSource,
    MOCK_REPOSITORY_STATUS,
    requests,
    { payloadExtras: PICKER_OPTIONS },
  );
  toggleCheckbox(cardCheckbox(document, "story.txt"));
  await waitFor(() => headerBulkAction(document, "stageFiles") != null, "the selection actions");
  selectOption(document.getElementById("source-select") as HTMLSelectElement, "staged");
  await waitFor(() => sessionOpens(requests) === 2, "the staged session");
  await waitFor(() => headerBulkAction(document, "unstageAll") != null, "the staged view's actions");
  expect(headerBulkAction(document, "unstageFiles")).toBeNull();
  await waitFor(() => cardCheckbox(document, "story.txt") != null, "the staged view's card");
  expect(cardCheckbox(document, "story.txt")?.getAttribute("aria-checked")).toBe("false");
});

test("the file list's rows carry the checkbox lane: clicking it toggles the selection without navigating, clicking the row navigates", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(
    unstagedSource,
    MOCK_REPOSITORY_STATUS,
    requests,
    { patch: TWO_FILE_PATCH },
  );
  await waitFor(() => cardCheckbox(document, "notes.txt") != null, "both cards");
  const shadow = document.querySelector("file-tree-container")?.shadowRoot ?? null;
  expect(shadow).toBeTruthy();
  const row = (name: string) =>
    shadow!.querySelector<HTMLElement>(`[data-item-type="file"][data-item-path="${name}"]`);
  await waitFor(() => row("notes.txt") != null, "the tree rows");
  const lane = row("notes.txt")!.querySelector<HTMLElement>('[data-item-section="decoration"]')!;
  expect(lane).toBeTruthy();
  expect(lane.querySelector("svg")?.getAttribute("data-icon-name")).toBe("cmux-select-off");
  expect(lane.querySelector("span")?.getAttribute("title")).toBe("Select notes.txt");
  const window = document.defaultView!;
  // The page names the file the diff is on: the first one, once the stream
  // has listed it.
  await waitFor(() => document.documentElement.dataset.activeFile === "story.txt", "the first file active");
  flushSync(() => {
    lane.dispatchEvent(new window.MouseEvent("click", { bubbles: true, composed: true, cancelable: true }));
  });
  await waitFor(() => headerBulkAction(document, "stageFiles") != null, "the selection actions");
  expect(cardCheckbox(document, "notes.txt")?.getAttribute("aria-checked")).toBe("true");
  expect(headerBulkLabels(document)[0]).toBe("Stage 1 file");
  // The row was not selected for navigation by that click.
  expect(document.documentElement.dataset.activeFile).toBe("story.txt");
  // The lane redraws as checked, and Space on the focused row unchecks it.
  await waitFor(
    () =>
      row("notes.txt")
        ?.querySelector('[data-item-section="decoration"] svg')
        ?.getAttribute("data-icon-name") === "cmux-select-on",
    "the checked glyph",
  );
  flushSync(() => {
    row("notes.txt")!.dispatchEvent(
      new window.KeyboardEvent("keydown", { key: " ", bubbles: true, composed: true, cancelable: true }),
    );
  });
  await waitFor(() => headerBulkAction(document, "stageAll") != null, "nothing selected");
  expect(cardCheckbox(document, "notes.txt")?.getAttribute("aria-checked")).toBe("false");
  expect(document.documentElement.dataset.activeFile).toBe("story.txt");
  // Clicking the row itself (its name, not the lane) does navigate, and
  // checks nothing.
  flushSync(() => {
    row("notes.txt")!.dispatchEvent(new window.MouseEvent("click", { bubbles: true, composed: true, cancelable: true }));
  });
  await waitFor(() => document.documentElement.dataset.activeFile === "notes.txt", "the row click to navigate");
  expect(cardCheckbox(document, "notes.txt")?.getAttribute("aria-checked")).toBe("false");
  expect(sessionOpens(requests)).toBe(1);
});

test("push posts worktreePush with setUpstream, reports the result, and refreshes the status", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(stagedSource, MOCK_GITHUB_STATUS, requests);
  click(document.getElementById("commit-menu-button") as HTMLButtonElement);
  click(menuAction(document, "push"));
  await waitFor(() => requestsFor(requests, "worktreePush").length === 1, "the push request");
  expect(requestsFor(requests, "worktreePush")[0].params).toEqual({
    sessionId,
    capabilityToken: token,
    source: stagedSource,
    setUpstream: true,
  });
  await waitFor(
    () =>
      document.getElementById("worktree-notice")?.textContent ===
      "Pushed main to origin and set the upstream",
    "the pushed notice",
  );
  expect(document.getElementById("worktree-notice")?.dataset.error).toBe("false");
  // No reload for a push (the diff did not change), one status refresh.
  await waitFor(
    () => requestsFor(requests, "worktreeRepositoryStatus").length === 2,
    "the status refresh",
  );
  expect(sessionOpens(requests)).toBe(1);
  expect(document.getElementById("commit-menu")).toBeNull();
});

test("push failures show the localized reason with the remote's last line", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(stagedSource, MOCK_GITHUB_STATUS, requests, {
    overrides: {
      worktreePush: (request) =>
        failureResponse(
          request,
          "pushRejected",
          "The remote rejected the push: ! [rejected] main -> main (fetch first)",
        ),
    },
  });
  click(document.getElementById("commit-menu-button") as HTMLButtonElement);
  click(menuAction(document, "push"));
  await waitFor(
    () =>
      document.getElementById("worktree-notice")?.textContent ===
      "The remote rejected the push. ! [rejected] main -> main (fetch first)",
    "the rejection notice",
  );
  expect(document.getElementById("worktree-notice")?.dataset.error).toBe("true");
  expect(sessionOpens(requests)).toBe(1);
});

test("creating a pull request validates the title, posts the draft, and shows the card", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(stagedSource, MOCK_GITHUB_STATUS, requests);
  click(document.getElementById("commit-menu-button") as HTMLButtonElement);
  click(menuAction(document, "createPullRequest"));
  const popover = document.getElementById("pull-request-popover")!;
  expect(popover.getAttribute("aria-label")).toBe("Create pull request");
  const submit = () =>
    document.querySelector<HTMLButtonElement>('#pull-request-popover [data-action="createPullRequest"]')!;
  expect(submit().textContent).toBe("Create pull request");
  // An empty title never leaves the page.
  expect(submit().disabled).toBe(true);
  submit().click();
  expect(requestsFor(requests, "worktreeCreatePullRequest")).toHaveLength(0);
  const title = popover.querySelector<HTMLInputElement>(".pull-request-title-input")!;
  setInputValue(title, "  Add widgets ");
  await waitFor(() => submit().disabled === false, "the submit button to enable");
  // An invalid base is flagged in place, still without a request.
  const base = popover.querySelector<HTMLInputElement>(".pull-request-base-input")!;
  setInputValue(base, "-force");
  click(submit());
  expect(popover.querySelector(".commit-popover-hint")?.textContent).toBe(
    "Enter a valid base branch name.",
  );
  expect(requestsFor(requests, "worktreeCreatePullRequest")).toHaveLength(0);
  setInputValue(base, "main");
  await waitFor(() => submit().disabled === false, "the submit button to re-enable");
  flushSync(() => popover.querySelector<HTMLInputElement>('input[type="checkbox"]')!.click());
  click(submit());
  await waitFor(
    () => requestsFor(requests, "worktreeCreatePullRequest").length === 1,
    "the create request",
  );
  expect(requestsFor(requests, "worktreeCreatePullRequest")[0].params).toEqual({
    sessionId,
    capabilityToken: token,
    source: stagedSource,
    title: "Add widgets",
    body: "",
    draft: true,
    base: "main",
  });
  await waitFor(
    () => document.getElementById("pull-request-card") != null,
    "the pull request card",
  );
  const card = document.getElementById("pull-request-card")!;
  expect(card.querySelector(".pull-request-number")?.textContent).toBe("#42");
  expect(card.querySelector(".pull-request-title")?.textContent).toBe("Add widgets");
  expect(card.querySelector(".pull-request-state")?.textContent).toBe("Draft");
  expect(document.getElementById("pull-request-popover")).toBeNull();
  expect(document.getElementById("worktree-notice")?.textContent).toBe("Created #42");
  await waitFor(
    () => requestsFor(requests, "worktreeRepositoryStatus").length === 2,
    "the status refresh",
  );
  expect(sessionOpens(requests)).toBe(1);
});

test("a forge that is not signed in shows the guidance notice for create", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(stagedSource, MOCK_GITHUB_STATUS, requests, {
    overrides: {
      worktreeCreatePullRequest: (request) =>
        failureResponse(request, "forgeNotAuthenticated", "The forge command-line tool is not signed in"),
    },
  });
  click(document.getElementById("commit-menu-button") as HTMLButtonElement);
  click(menuAction(document, "createPullRequest"));
  setInputValue(
    document.querySelector<HTMLInputElement>(".pull-request-title-input")!,
    "Add widgets",
  );
  const submit = document.querySelector<HTMLButtonElement>(
    '#pull-request-popover [data-action="createPullRequest"]',
  )!;
  await waitFor(() => !submit.disabled, "the submit button to enable");
  click(submit);
  await waitFor(
    () =>
      document.getElementById("worktree-notice")?.textContent ===
      "Sign in with gh auth login or glab auth login, then try again.",
    "the guidance notice",
  );
  expect(document.getElementById("worktree-notice")?.dataset.error).toBe("true");
});

test("the unstaged view commits through stage all and commit", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(unstagedSource, MOCK_REPOSITORY_STATUS, requests);
  click(document.getElementById("commit-button") as HTMLButtonElement);
  const submit = () => findButton(document, "Stage all and commit", "#commit-popover");
  expect(submit()).toBeTruthy();
  expect(submit()?.dataset.stageAll).toBe("true");
  setTextareaValue(
    document.querySelector<HTMLTextAreaElement>(".commit-message-input")!,
    "Ship everything",
  );
  await waitFor(() => submit()?.disabled === false, "the submit button to enable");
  click(submit());
  await waitFor(() => requestsFor(requests, "worktreeCommit").length === 1, "the commit request");
  expect(requestsFor(requests, "worktreeCommit")[0].params).toEqual({
    sessionId,
    capabilityToken: token,
    source: unstagedSource,
    message: "Ship everything",
    stageAll: true,
  });
  await waitFor(() => sessionOpens(requests) === 2, "the session to reopen");
  // The reopened session refetches the status: the branch moved ahead.
  await waitFor(
    () => requestsFor(requests, "worktreeRepositoryStatus").length === 2,
    "the status refresh after the commit",
    3000,
  );
});

test("file cards offer open in cmux (host action) and copy path", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(unstagedSource, MOCK_REPOSITORY_STATUS, requests);
  const copied: string[] = [];
  Object.defineProperty(document.defaultView!.navigator, "clipboard", {
    configurable: true,
    value: { writeText: async (text: string) => { copied.push(text); } },
  });
  click(headerAction(document, "openInCmux"));
  await waitFor(() => requestsFor(requests, "hostOpenFile").length === 1, "the host open request");
  expect(requestsFor(requests, "hostOpenFile")[0]).toMatchObject({
    version: 1,
    method: "hostOpenFile",
    params: { capabilityToken: token, path: "story.txt" },
  });
  // Opening never reloads the diff or disables the actions.
  expect(sessionOpens(requests)).toBe(1);
  expect(document.querySelector<HTMLElement>(".worktree-file-actions")?.dataset.pending).toBe("false");
  click(headerAction(document, "copyPath"));
  await waitFor(() => copied.length === 1, "the clipboard write");
  expect(copied).toEqual(["story.txt"]);
  await waitFor(
    () => document.getElementById("copy-feedback")?.textContent === "Copied path",
    "the copy feedback",
  );
});

test("open in cmux failures surface as a notice", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(unstagedSource, MOCK_REPOSITORY_STATUS, requests, {
    overrides: {
      hostOpenFile: (request) => failureResponse(request, "notAllowed", "Diff sidecar request was rejected"),
    },
  });
  click(headerAction(document, "openInCmux"));
  await waitFor(
    () =>
      document.getElementById("worktree-notice")?.textContent === "Could not open the file in cmux.",
    "the failure notice",
  );
  expect(document.getElementById("worktree-notice")?.dataset.error).toBe("true");
});

// MARK: Header hosts the pickers; per-file fold

/**
 * Opens the view's "..." menu unless it is already open: the repository
 * header's in working-tree views, the toolbar's otherwise. Header-action
 * clicks stop propagation, so an open menu survives them; toggling blindly
 * would close it.
 */
async function openOptionsMenu(document: Document): Promise<void> {
  const menuOpen = () =>
    document.getElementById("repo-overflow-menu") != null ||
    document.getElementById("options-menu") != null;
  if (!menuOpen()) {
    (
      document.getElementById("repo-overflow-button") ??
      document.getElementById("options-button")
    )?.click();
  }
  await waitFor(menuOpen, "the options menu");
}

function selectOption(select: HTMLSelectElement, value: string): void {
  const window = select.ownerDocument.defaultView!;
  select.value = value;
  flushSync(() => {
    select.dispatchEvent(new window.Event("change", { bubbles: true }));
  });
}

test("a working-tree view hosts the source and repo pickers in the repository header, not the toolbar", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderApp(
    unstagedSource,
    sidecarMock(requests, ["worktree.write"]),
    { patch: ONE_FILE_PATCH, payloadExtras: PICKER_OPTIONS },
  );
  await waitFor(
    () => Boolean(document.getElementById("repo-header")),
    "the repository header",
  );
  const header = document.getElementById("repo-header")!;
  // The header is the view's only top row: no toolbar, and exactly one copy
  // of the pickers, in the header.
  expect(document.getElementById("toolbar")).toBeNull();
  expect(document.querySelectorAll("#source-select")).toHaveLength(1);
  expect(header.querySelector("#source-select")).toBeTruthy();
  expect(header.querySelector("#repo-select")).toBeTruthy();
  // The repo select replaces the plain repo label and carries its path.
  expect(header.querySelector(".repo-header-repo")).toBeNull();
  expect(header.querySelector<HTMLSelectElement>("#repo-select")?.title).toBe(
    "/tmp/repo",
  );
  // Header, then the diffs.
  expect(header.nextElementSibling?.id).toBe("content");
  // One "..." menu for the view, with the files-list toggle beside it.
  expect(
    document.querySelectorAll("#options-button, #repo-overflow-button"),
  ).toHaveLength(1);
  expect(header.querySelector("#files-toggle")?.getAttribute("aria-pressed")).toBe(
    "true",
  );
  // Switching the source from the header opens the new session.
  selectOption(header.querySelector<HTMLSelectElement>("#source-select")!, "staged");
  await waitFor(() => sessionOpens(requests) === 2, "the staged session");
  expect(requestsFor(requests, "sessionOpen")[1].params.source).toEqual(stagedSource);
});

test("a patch session keeps the pickers in the toolbar and renders no repository header", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderApp(
    { kind: "patch", path: "/last-turn.patch" },
    sidecarMock(requests, ["worktree.write"]),
    { payloadExtras: PICKER_OPTIONS },
  );
  await waitFor(
    () => requests.some((request) => request.method === "protocolHandshake"),
    "the handshake",
  );
  expect(document.getElementById("repo-header")).toBeNull();
  const toolbar = document.getElementById("toolbar")!;
  // The toolbar keeps its own "..." menu; there is no header menu to share.
  expect(toolbar.querySelector("#options-button")).toBeTruthy();
  expect(document.getElementById("repo-overflow-button")).toBeNull();
  expect(toolbar.querySelector("#source-select")).toBeTruthy();
  expect(document.querySelectorAll("#source-select")).toHaveLength(1);
  // Patch sessions have no repository to pick.
  expect(document.getElementById("repo-select")).toBeNull();
  // The file list column owns file navigation; the toolbar carries no
  // jump-to-file control of its own.
  expect(
    toolbar.querySelector(".toolbar-middle, #jump-select, #jump-search-button"),
  ).toBeNull();
});

/**
 * Every file card. The library renders the card header in its worker, which
 * JSDOM never runs, so a card is known by its element and, when the file
 * matters, by the path its "Open in cmux" action reports (`pathOf`).
 */
function cards(document: Document): HTMLElement[] {
  return Array.from(document.querySelectorAll<HTMLElement>("diffs-container"));
}

function codeBlocksIn(card: HTMLElement): number {
  return card.shadowRoot?.querySelectorAll("pre").length ?? 0;
}

function foldToggle(card: HTMLElement): HTMLButtonElement {
  const toggle = card.querySelector<HTMLButtonElement>(".file-collapse-toggle");
  expect(toggle).toBeTruthy();
  return toggle!;
}

function isExpanded(card: HTMLElement): boolean {
  return foldToggle(card).getAttribute("aria-expanded") === "true";
}

/** The card's file path, learned from its host open request (never a reload). */
async function pathOf(card: HTMLElement, requests: SidecarRequest[]): Promise<string> {
  const before = requestsFor(requests, "hostOpenFile").length;
  click(card.querySelector<HTMLButtonElement>('[data-action="openInCmux"]'));
  await waitFor(
    () => requestsFor(requests, "hostOpenFile").length === before + 1,
    "the host open request",
  );
  return requestsFor(requests, "hostOpenFile")[before].params.path;
}

test("a file card folds from its header chevron and unfolds again", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderApp(
    unstagedSource,
    sidecarMock(requests, ["worktree.write"]),
    { patch: ONE_FILE_PATCH },
  );
  await waitFor(() => renderedCodeBlocks(document) === 1, "the file's code");
  const [card] = cards(document);
  expect(isExpanded(card)).toBe(true);
  expect(foldToggle(card).title).toBe("Collapse file");
  click(foldToggle(card));
  // The controlled `collapsed` reaches CodeView: the card keeps its header
  // (chevron and write actions) but renders no code.
  await waitFor(() => codeBlocksIn(card) === 0, "the card to fold");
  await waitFor(() => !isExpanded(card), "the chevron to report the fold");
  expect(foldToggle(card).title).toBe("Expand file");
  expect(card.querySelectorAll(".worktree-action")).toHaveLength(4);
  // A single fold leaves the collapse-all option alone.
  await openOptionsMenu(document);
  expect(findButton(document, "Collapse all diffs")).toBeTruthy();
  expect(findButton(document, "Expand all diffs")).toBeUndefined();
  click(foldToggle(card));
  await waitFor(() => codeBlocksIn(card) === 1, "the card to unfold");
  await waitFor(() => isExpanded(card), "the chevron to report the unfold");
  expect(foldToggle(card).title).toBe("Collapse file");
  // No fold ever touches the session.
  expect(sessionOpens(requests)).toBe(1);
});

test("collapse all then a per-file expand reopens only that card, and both survive a write reload", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderApp(
    unstagedSource,
    sidecarMock(requests, ["worktree.write"]),
    { patch: TWO_FILE_PATCH },
  );
  await waitFor(() => renderedCodeBlocks(document) === 2, "both files' code");
  expect(cards(document)).toHaveLength(2);
  await openOptionsMenu(document);
  click(findButton(document, "Collapse all diffs"));
  await waitFor(() => renderedCodeBlocks(document) === 0, "every card to fold");
  await waitFor(
    () => cards(document).every((card) => !isExpanded(card)),
    "every chevron to report the fold",
  );
  // Expanding one card from its chevron leaves the other folded and the
  // collapse-all option on.
  const [first, second] = cards(document);
  click(foldToggle(first));
  await waitFor(() => codeBlocksIn(first) === 1, "the first card to unfold");
  expect(isExpanded(first)).toBe(true);
  expect(codeBlocksIn(second)).toBe(0);
  expect(isExpanded(second)).toBe(false);
  expect(renderedCodeBlocks(document)).toBe(1);
  const expandedPath = await pathOf(first, requests);
  expect(["story.txt", "notes.txt"]).toContain(expandedPath);
  await openOptionsMenu(document);
  expect(findButton(document, "Expand all diffs")).toBeTruthy();
  // A write reloads the session in place; the re-streamed cards come back
  // with the same folds: the per-file expand (keyed by path, so it finds its
  // file again) and the collapse-all baseline for the rest.
  click(first.querySelector<HTMLButtonElement>('[data-action="stageFile"]'));
  await waitForReload(document, requests);
  await waitFor(
    () => document.body.dataset.streamFileCount === "2",
    "both files to stream again",
  );
  await waitFor(
    () => cards(document).length === 2 && renderedCodeBlocks(document) === 1,
    "one card to come back open",
  );
  const reopened = cards(document).filter(isExpanded);
  expect(reopened).toHaveLength(1);
  expect(codeBlocksIn(reopened[0])).toBe(1);
  expect(await pathOf(reopened[0], requests)).toBe(expandedPath);
  // Expand all resets the per-file choices: every card opens.
  await openOptionsMenu(document);
  click(findButton(document, "Expand all diffs"));
  await waitFor(() => renderedCodeBlocks(document) === 2, "every card to unfold");
  expect(cards(document).every(isExpanded)).toBe(true);
  // Folding one card again after expand all works from a clean slate.
  const [, other] = cards(document);
  click(foldToggle(other));
  await waitFor(() => codeBlocksIn(other) === 0, "the second card to fold");
  expect(renderedCodeBlocks(document)).toBe(1);
});

// MARK: Repo picker only with a choice; host in-place refresh

const SINGLE_REPO_OPTIONS = {
  sourceOptions: PICKER_OPTIONS.sourceOptions,
  repoOptions: PICKER_OPTIONS.repoOptions.slice(0, 1),
  repoRoot: "/Users/dev/src/widgets",
  repoLabel: "~/src/widgets",
};

test("the header names a single repository as text and offers the picker only with a choice", async () => {
  // One repository (the docked panel follows the workspace): no picker, the
  // abbreviated path precedes the branch.
  const single: SidecarRequest[] = [];
  const singleDocument = await renderApp(
    { kind: "unstaged", repoRoot: "/Users/dev/src/widgets" },
    sidecarMock(single, ["worktree.write"]),
    { patch: ONE_FILE_PATCH, payloadExtras: SINGLE_REPO_OPTIONS },
  );
  await waitFor(
    () => singleDocument.querySelector(".repo-header-branch") != null,
    "the status to render",
  );
  const singleHeader = singleDocument.getElementById("repo-header")!;
  expect(singleHeader.querySelector("#source-select")).toBeTruthy();
  expect(singleDocument.getElementById("repo-select")).toBeNull();
  expect(singleHeader.querySelector(".repo-header-repo")?.textContent).toBe(
    "~/src/widgets",
  );
  expect(singleHeader.querySelector(".repo-header-separator")?.textContent).toBe(":");
  expect(singleHeader.querySelector(".repo-header-branch")?.textContent).toBe("main");
  expect(singleHeader.querySelector(".repo-header-title")?.getAttribute("title")).toBe(
    "/Users/dev/src/widgets",
  );
  await resetDom();
  // Two repositories: the picker replaces the text.
  const multi: SidecarRequest[] = [];
  const multiDocument = await renderApp(
    unstagedSource,
    sidecarMock(multi, ["worktree.write"]),
    { patch: ONE_FILE_PATCH, payloadExtras: PICKER_OPTIONS },
  );
  await waitFor(
    () => multiDocument.querySelector(".repo-header-branch") != null,
    "the status to render",
  );
  const multiHeader = multiDocument.getElementById("repo-header")!;
  expect(multiHeader.querySelector("#repo-select")).toBeTruthy();
  expect(multiHeader.querySelector(".repo-header-repo")).toBeNull();
  expect(multiHeader.querySelector(".repo-header-separator")).toBeNull();
  expect(multiHeader.querySelector(".repo-header-branch")?.textContent).toBe("main");
});

test("the toolbar fallback also renders the repo picker only with two or more repositories", async () => {
  // A branch session is read-only, so the toolbar hosts the pickers.
  const branchSource = { kind: "branch", repoRoot: "/tmp/repo", baseRef: "main" };
  const single: SidecarRequest[] = [];
  const singleDocument = await renderApp(
    branchSource,
    sidecarMock(single, ["worktree.write"]),
    { payloadExtras: SINGLE_REPO_OPTIONS },
  );
  expect(singleDocument.getElementById("repo-header")).toBeNull();
  expect(singleDocument.getElementById("toolbar")).toBeTruthy();
  expect(singleDocument.querySelector("#toolbar #source-select")).toBeTruthy();
  expect(singleDocument.getElementById("repo-select")).toBeNull();
  await resetDom();
  const multi: SidecarRequest[] = [];
  const multiDocument = await renderApp(
    branchSource,
    sidecarMock(multi, ["worktree.write"]),
    { payloadExtras: PICKER_OPTIONS },
  );
  expect(multiDocument.getElementById("repo-header")).toBeNull();
  expect(multiDocument.querySelector("#toolbar #repo-select")).toBeTruthy();
  expect(multiDocument.querySelectorAll("#repo-select")).toHaveLength(1);
});

test("window.cmuxDiffViewer.refresh() reopens the working-tree session in place and keeps the folds and status", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(unstagedSource, MOCK_GITHUB_STATUS, requests);
  const window = document.defaultView!;
  await waitFor(() => renderedCodeBlocks(document) === 1, "the file's code");
  expect(requestsFor(requests, "worktreeRepositoryStatus")).toHaveLength(1);
  // Fold the card first: the refresh must bring it back folded.
  const [card] = cards(document);
  click(foldToggle(card));
  await waitFor(() => codeBlocksIn(card) === 0, "the card to fold");
  const before = requests.length;
  expect(window.cmuxDiffViewer?.refresh()).toBe(true);
  // While the reload is in flight a second refresh is refused, like a write.
  expect(window.cmuxDiffViewer?.refresh()).toBe(false);
  await waitForReload(document, requests);
  // The same source was closed and reopened, in that order, with no
  // navigation and no status refetch.
  const afterwards = requests.slice(before).map((request) => request.method);
  expect(afterwards.indexOf("sessionClose")).toBeGreaterThanOrEqual(0);
  expect(afterwards.indexOf("sessionClose")).toBeLessThan(afterwards.indexOf("sessionOpen"));
  expect(requestsFor(requests, "sessionOpen")[1].params.source).toEqual(unstagedSource);
  expect(window.location.href).toBe(viewerURL);
  expect(requestsFor(requests, "worktreeRepositoryStatus")).toHaveLength(1);
  expect(document.querySelector(".repo-header-position")?.textContent).toBe("2 ahead");
  await waitFor(
    () => document.body.dataset.streamFileCount === "1" && cards(document).length === 1,
    "the file to stream again",
  );
  expect(codeBlocksIn(cards(document)[0])).toBe(0);
  expect(isExpanded(cards(document)[0])).toBe(false);
  // Once settled, a refresh is accepted again.
  expect(window.cmuxDiffViewer?.refresh()).toBe(true);
  await waitFor(() => sessionOpens(requests) === 3, "the third session");
});

test("window.cmuxDiffViewer.refresh() is refused while a write is pending", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderApp(
    unstagedSource,
    sidecarMock(requests, ["worktree.write"]),
    { patch: ONE_FILE_PATCH },
  );
  click(headerAction(document, "stageFile"));
  expect(document.defaultView!.cmuxDiffViewer?.refresh()).toBe(false);
  await waitForReload(document, requests);
  // Exactly the write's reload happened.
  expect(sessionOpens(requests)).toBe(2);
});

test("a patch session has no in-place refresh", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderApp(
    { kind: "patch", path: "/last-turn.patch" },
    sidecarMock(requests, ["worktree.write"]),
    { payloadExtras: PICKER_OPTIONS },
  );
  expect(document.defaultView!.cmuxDiffViewer?.refresh() ?? false).toBe(false);
  // The refused refresh reopened nothing: the next session open is the
  // picker's, for the source it chose.
  selectOption(document.getElementById("source-select") as HTMLSelectElement, "staged");
  await waitFor(() => sessionOpens(requests) === 2, "the staged session");
  expect(requestsFor(requests, "sessionOpen").map((request) => request.params.source)).toEqual([
    { kind: "patch", path: "/last-turn.patch" },
    stagedSource,
  ]);
});

// MARK: One "..." menu per view, shared view options

const VIEW_OPTION_LABELS = [
  "Enable word wrap",
  "Collapse all diffs",
  "Switch to split diff",
  "Hide files",
  "Expand unchanged context",
  "Hide backgrounds",
  "Hide line numbers",
  "Enable word diffs",
];

function segmentButton(document: Document, label: string) {
  return document.querySelector<HTMLButtonElement>(
    `.menu-segment-controls [aria-label="${label}"]`,
  );
}

test("the header menu lists the repo actions and every view option, and each option dispatches the shared action", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(unstagedSource, MOCK_GITHUB_STATUS, requests);
  await waitFor(() => renderedCodeBlocks(document) === 1, "the file's code");
  await openOptionsMenu(document);
  const menu = document.getElementById("repo-overflow-menu")!;
  expect(menu).toBeTruthy();
  expect(document.getElementById("options-menu")).toBeNull();
  // The batch actions, a separator, the view options, a separator,
  // copy/refresh: three groups, the actions first.
  for (const text of [
    "Stage all",
    "Discard all changes…",
    ...VIEW_OPTION_LABELS,
    "Copy git apply command",
    "Refresh",
  ]) {
    expect(findButton(document, text, "#repo-overflow-menu")).toBeTruthy();
  }
  expect(headerBulkLabels(document)).toEqual(["Stage all", "Discard all changes…"]);
  expect(menu.querySelectorAll(".menu-separator")).toHaveLength(2);
  expect(menu.querySelectorAll(".menu-segment-controls .segment-button")).toHaveLength(3);
  const order = Array.from(menu.children).map((child) =>
    child.classList.contains("menu-separator")
      ? "|"
      : child.textContent?.trim() ?? "",
  );
  expect(order.indexOf("|")).toBeGreaterThan(order.indexOf("Discard all changes…"));
  expect(order.indexOf("|")).toBeLessThan(order.indexOf("Enable word wrap"));
  expect(order.lastIndexOf("|")).toBeGreaterThan(order.indexOf("Enable word diffs"));
  expect(order.lastIndexOf("|")).toBeLessThan(order.indexOf("Refresh"));
  // Each option dispatches the same reducer action as the toolbar menu; the
  // page attributes observe the resulting state.
  click(findButton(document, "Switch to split diff", "#repo-overflow-menu"));
  await waitFor(
    () => document.documentElement.dataset.layout === "split",
    "the split layout",
  );
  expect(findButton(document, "Switch to unified diff", "#repo-overflow-menu")).toBeTruthy();
  click(findButton(document, "Collapse all diffs", "#repo-overflow-menu"));
  await waitFor(() => renderedCodeBlocks(document) === 0, "every card to fold");
  expect(findButton(document, "Expand all diffs", "#repo-overflow-menu")).toBeTruthy();
  click(findButton(document, "Hide files", "#repo-overflow-menu"));
  await waitFor(
    () => document.body.dataset.filesHidden === "true",
    "the files list to hide",
  );
  expect(document.getElementById("files-toggle")?.getAttribute("aria-pressed")).toBe(
    "false",
  );
  expect(findButton(document, "Show files", "#repo-overflow-menu")).toBeTruthy();
  click(segmentButton(document, "Classic"));
  await waitFor(
    () => document.documentElement.dataset.diffIndicators === "classic",
    "the classic indicators",
  );
  expect(segmentButton(document, "Classic")?.getAttribute("aria-pressed")).toBe("true");
  expect(segmentButton(document, "Bars")?.getAttribute("aria-pressed")).toBe("false");
  // The header's files-list toggle drives the same state.
  click(document.getElementById("files-toggle") as HTMLButtonElement);
  await waitFor(
    () => document.body.dataset.filesHidden === "false",
    "the files list to show again",
  );
  expect(document.getElementById("files-toggle")?.getAttribute("aria-pressed")).toBe(
    "true",
  );
  // None of this touched the session.
  expect(sessionOpens(requests)).toBe(1);
});

test("a patch session keeps the toolbar's own options menu with the same view options", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderApp(
    { kind: "patch", path: "/last-turn.patch" },
    sidecarMock(requests, ["worktree.write"]),
    { payloadExtras: PICKER_OPTIONS },
  );
  await openOptionsMenu(document);
  const menu = document.getElementById("options-menu")!;
  expect(menu).toBeTruthy();
  expect(document.getElementById("repo-overflow-menu")).toBeNull();
  for (const text of ["Refresh", ...VIEW_OPTION_LABELS, "Copy git apply command"]) {
    expect(findButton(document, text, "#options-menu")).toBeTruthy();
  }
  expect(menu.querySelectorAll(".menu-segment-controls .segment-button")).toHaveLength(3);
  click(findButton(document, "Switch to split diff", "#options-menu"));
  await waitFor(
    () => document.documentElement.dataset.layout === "split",
    "the split layout",
  );
  click(segmentButton(document, "None"));
  await waitFor(
    () => document.documentElement.dataset.diffIndicators === "none",
    "no indicators",
  );
});
