import { expect, test } from "bun:test";
import { flushSync } from "react-dom";
import { renderToStaticMarkup } from "react-dom/server";
import { App } from "../src/App";
import { createDiffViewerLabelResolver } from "../src/labels";
import { createDiffViewerStatus } from "../src/status";
import { FileWriteActions, HunkWriteActions } from "../src/WorktreeActions";
import {
  click,
  emptyFetch,
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

/**
 * Mounts the App on a typed WebKit session against `mock`. With a `patch`,
 * every patch fetch streams it and the render waits for its file header
 * actions; otherwise the diff is empty and the render waits for that.
 * `payloadExtras` adds to the page payload (picker options, for instance).
 */
async function renderApp(
  source: any,
  mock: ReturnType<typeof sidecarMock>,
  patch = "",
  payloadExtras: Record<string, unknown> = {},
) {
  const dom = mountDom(
    viewerURL,
    patch === "" ? emptyFetch : () => new Response(patch, { status: 200 }),
  );
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

test("file header actions render per source kind and confirm before reverting", () => {
  const unstagedMarkup = renderToStaticMarkup(
    <FileWriteActions
      actions={["stageFile", "revertFile"]}
      label={label}
      onAction={() => {}}
      pending={false}
    />,
  );
  expect(unstagedMarkup).toContain('data-action="stageFile"');
  expect(unstagedMarkup).toContain('data-action="revertFile"');
  expect(unstagedMarkup).not.toContain('data-action="unstageFile"');
  const stagedMarkup = renderToStaticMarkup(
    <FileWriteActions
      actions={["unstageFile", "revertFile"]}
      label={label}
      onAction={() => {}}
      pending={false}
    />,
  );
  expect(stagedMarkup).toContain('data-action="unstageFile"');
  expect(stagedMarkup).not.toContain('data-action="stageFile"');
  expect(
    renderToStaticMarkup(
      <FileWriteActions
        actions={[]}
        label={label}
        onAction={() => {}}
        pending={false}
      />,
    ),
  ).toBe("");

  const dom = mountDom();
  const actions: string[] = [];
  render(
    <FileWriteActions
      actions={["stageFile", "revertFile"]}
      label={label}
      onAction={(action) => actions.push(action)}
      pending={false}
    />,
  );
  const document = dom.window.document;
  click(document.querySelector<HTMLButtonElement>('[data-action="stageFile"]'));
  expect(actions).toEqual(["stageFile"]);
  click(
    document.querySelector<HTMLButtonElement>('[data-action="revertFile"]'),
  );
  // Revert asks first; nothing has been sent yet.
  expect(actions).toEqual(["stageFile"]);
  expect(document.querySelector(".worktree-confirm-text")?.textContent).toBe(
    "Discard these changes?",
  );
  click(findButton(document, "Cancel"));
  expect(document.querySelector(".worktree-confirm")).toBeNull();
  click(
    document.querySelector<HTMLButtonElement>('[data-action="revertFile"]'),
  );
  click(findButton(document, "Revert"));
  expect(actions).toEqual(["stageFile", "revertFile"]);
});

test("header action cluster stops the header toggle but lets other keys reach the document", () => {
  const dom = mountDom();
  const seen: string[] = [];
  render(
    // oxlint-disable-next-line jsx-a11y/no-static-element-interactions
    <div onKeyDown={(event) => seen.push(event.key)}>
      <FileWriteActions
        actions={["stageFile", "revertFile"]}
        label={label}
        onAction={() => {}}
        pending={false}
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

test("hunk action row confirms a revert and disables while a write is pending", () => {
  const dom = mountDom();
  let reverts = 0;
  render(
    <HunkWriteActions
      label={label}
      onRevert={() => {
        reverts += 1;
      }}
      pending={false}
    />,
  );
  const document = dom.window.document;
  click(document.querySelector<HTMLButtonElement>(".worktree-hunk-button"));
  expect(reverts).toBe(0);
  click(findButton(document, "Revert"));
  expect(reverts).toBe(1);
  rerender(<HunkWriteActions label={label} onRevert={() => {}} pending />);
  expect(
    document.querySelector<HTMLButtonElement>(".worktree-hunk-button")
      ?.disabled,
  ).toBe(true);
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

test("header Stage sends worktreeStageFile for the streamed file and reopens the session", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderApp(
    unstagedSource,
    sidecarMock(requests, ["worktree.write"]),
    ONE_FILE_PATCH,
  );
  expect(document.querySelectorAll(".worktree-hunk-button")).toHaveLength(1);
  click(headerAction(document, "stageFile"));
  await waitFor(
    () => requestsFor(requests, "worktreeStageFile").length === 1,
    "the stage request",
  );
  expect(requestsFor(requests, "worktreeStageFile")[0].params).toEqual({
    sessionId,
    capabilityToken: token,
    source: unstagedSource,
    path: "story.txt",
  });
  await waitForReload(document, requests);
  expect(requestsFor(requests, "sessionOpen")[1].params.source).toEqual(
    unstagedSource,
  );
  // The reloaded file renders its actions again, header and hunk row alike.
  expect(headerAction(document, "stageFile")?.disabled).toBe(false);
  await waitFor(
    () => document.querySelectorAll(".worktree-hunk-button").length === 1,
    "the reloaded hunk row",
  );
  expect(document.getElementById("worktree-notice")).toBeNull();
});

test("header Revert confirms first, then sends worktreeRevertFile", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderApp(
    unstagedSource,
    sidecarMock(requests, ["worktree.write"]),
    ONE_FILE_PATCH,
  );
  click(headerAction(document, "revertFile"));
  expect(requestsFor(requests, "worktreeRevertFile")).toHaveLength(0);
  expect(document.querySelector(".worktree-confirm-text")?.textContent).toBe(
    "Discard these changes?",
  );
  click(findButton(document, "Revert", ".worktree-file-actions"));
  await waitFor(
    () => requestsFor(requests, "worktreeRevertFile").length === 1,
    "the revert request",
  );
  expect(requestsFor(requests, "worktreeRevertFile")[0].params).toEqual({
    sessionId,
    capabilityToken: token,
    source: unstagedSource,
    path: "story.txt",
  });
  await waitForReload(document, requests);
});

test("hunk row Revert sends worktreeRevertHunk with the hunk's header ranges", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderApp(
    stagedSource,
    sidecarMock(requests, ["worktree.write"]),
    ONE_FILE_PATCH,
  );
  click(document.querySelector<HTMLButtonElement>(".worktree-hunk-button"));
  expect(requestsFor(requests, "worktreeRevertHunk")).toHaveLength(0);
  click(findButton(document, "Revert", ".worktree-hunk-actions"));
  await waitFor(
    () => requestsFor(requests, "worktreeRevertHunk").length === 1,
    "the hunk revert request",
  );
  expect(requestsFor(requests, "worktreeRevertHunk")[0].params).toEqual({
    sessionId,
    capabilityToken: token,
    source: stagedSource,
    path: "story.txt",
    hunk: ONE_FILE_HUNK,
  });
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
      stagedSource,
      sidecarMock(requests, ["worktree.write"], {
        worktreeRevertHunk: (request) =>
          failureResponse(request, code, message),
      }),
      ONE_FILE_PATCH,
    );
    click(document.querySelector<HTMLButtonElement>(".worktree-hunk-button"));
    click(findButton(document, "Revert", ".worktree-hunk-actions"));
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
    worktreeUnstageFile: async (request) => {
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
  const document = await renderApp(stagedSource, mock, ONE_FILE_PATCH);
  const commitButton = document.getElementById(
    "commit-button",
  ) as HTMLButtonElement;
  await waitFor(() => !commitButton.disabled, "the commit button to enable");
  click(headerAction(document, "unstageFile"));
  await waitFor(
    () => requestsFor(requests, "worktreeUnstageFile").length === 1,
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
  expect(requestsFor(requests, "worktreeUnstageFile")).toHaveLength(1);
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
  expect(requestsFor(requests, "worktreeUnstageFile")).toHaveLength(1);
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
    ONE_FILE_PATCH,
  );
  await waitFor(() => renderedCodeBlocks(document) === 1, "the file's code");
  await openOptionsMenu(document);
  click(findButton(document, "Collapse all diffs"));
  // A collapsed file keeps its header (and header actions) but renders no
  // code.
  await waitFor(() => renderedCodeBlocks(document) === 0, "the file to collapse");
  // Open in cmux, copy path, stage, revert.
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

/** Mounts a working-tree view whose status answers with `status`. */
async function renderWithStatus(
  source: any,
  status: Record<string, unknown>,
  requests: SidecarRequest[],
  overrides: Record<string, (request: SidecarRequest) => unknown> = {},
) {
  const document = await renderApp(
    source,
    sidecarMock(requests, ["worktree.write"], {
      worktreeRepositoryStatus: (request) => repositoryStatusResponse(request, status),
      ...overrides,
    }),
    ONE_FILE_PATCH,
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

test("the repository header shows the repo, branch, streamed totals, and upstream position", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(unstagedSource, MOCK_GITHUB_STATUS, requests);
  const header = document.getElementById("repo-header")!;
  expect(header.querySelector(".repo-header-repo")?.textContent).toBe("/tmp/repo");
  expect(header.querySelector(".repo-header-title")?.getAttribute("title")).toBe("/tmp/repo");
  expect(header.querySelector(".repo-header-branch")?.textContent).toBe("main");
  // The totals come from the streamed metrics: one file, +1 / -1.
  expect(header.querySelector(".repo-header-files")?.textContent).toBe("1 files");
  expect(header.querySelector(".repo-header-additions")?.textContent).toBe("+1");
  expect(header.querySelector(".repo-header-deletions")?.textContent).toBe("-1");
  expect(header.querySelector(".repo-header-position")?.textContent).toBe("2 ahead");
  // One status query per opened view: no polling.
  expect(requestsFor(requests, "worktreeRepositoryStatus")).toHaveLength(1);
  expect(requestsFor(requests, "worktreeRepositoryStatus")[0].params).toEqual({
    sessionId,
    capabilityToken: token,
    source: unstagedSource,
  });
  await new Promise((resolve) => setTimeout(resolve, 20));
  expect(requestsFor(requests, "worktreeRepositoryStatus")).toHaveLength(1);
});

test("a home-directory repository is abbreviated with ~ in the header", async () => {
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
        remoteUrl: "git@gitlab.com:acme/widgets.git",
        hostKind: "gitlab",
        forgeCli: { kind: "glab", available: true, authenticated: false },
      },
      push: true,
      create: false,
      createLabel: "Create MR",
      createHint: "Sign in with gh auth login or glab auth login, then try again.",
    },
    {
      status: {
        ...MOCK_GITHUB_STATUS,
        forgeCli: { kind: "gh", available: false, authenticated: false },
      },
      push: true,
      create: false,
      createLabel: "Create PR",
      createHint: "Install the GitHub CLI (gh) or GitLab CLI (glab) to use this action.",
    },
    {
      status: { ...MOCK_REPOSITORY_STATUS, upstream: undefined, remoteUrl: undefined, hostKind: "none" },
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
      forgeCli: { kind: "glab", available: true, authenticated: true },
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

test("discard all confirms inline and posts worktreeDiscardAll exactly once", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(unstagedSource, MOCK_REPOSITORY_STATUS, requests);
  click(document.getElementById("repo-overflow-button") as HTMLButtonElement);
  expect(menuAction(document, "stageAll")).toBeTruthy();
  expect(menuAction(document, "unstageAll")).toBeNull();
  click(menuAction(document, "discardAll"));
  // Asking is not doing: nothing has been sent, the prompt is shown.
  expect(requestsFor(requests, "worktreeDiscardAll")).toHaveLength(0);
  expect(document.querySelector("#repo-overflow-menu .worktree-confirm-text")?.textContent).toBe(
    "Discard every change in this view? This cannot be undone.",
  );
  // Cancel keeps the menu and sends nothing.
  click(document.querySelector<HTMLButtonElement>('#repo-overflow-menu [data-action="cancel"]'));
  expect(document.getElementById("repo-overflow-menu")).toBeTruthy();
  expect(menuAction(document, "discardAll")).toBeTruthy();
  expect(requestsFor(requests, "worktreeDiscardAll")).toHaveLength(0);
  click(menuAction(document, "discardAll"));
  const confirm = document.querySelector<HTMLButtonElement>('#repo-overflow-menu [data-action="confirm"]')!;
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
  expect(document.getElementById("repo-overflow-menu")).toBeNull();
  await waitForReload(document, requests);
  expect(requestsFor(requests, "worktreeDiscardAll")).toHaveLength(1);
});

test("a failed discard all reloads the diff: Git may have restored some paths before giving up", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderWithStatus(unstagedSource, MOCK_REPOSITORY_STATUS, requests, {
    worktreeDiscardAll: (request) =>
      failureResponse(request, "worktreeWriteFailed", "Could not update the working tree"),
  });
  click(document.getElementById("repo-overflow-button") as HTMLButtonElement);
  click(menuAction(document, "discardAll"));
  click(document.querySelector<HTMLButtonElement>('#repo-overflow-menu [data-action="confirm"]'));
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
  click(document.getElementById("repo-overflow-button") as HTMLButtonElement);
  expect(menuAction(document, "stageAll")).toBeNull();
  click(menuAction(document, "unstageAll"));
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
    worktreePush: (request) =>
      failureResponse(
        request,
        "pushRejected",
        "The remote rejected the push: ! [rejected] main -> main (fetch first)",
      ),
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
    worktreeCreatePullRequest: (request) =>
      failureResponse(request, "forgeNotAuthenticated", "The forge command-line tool is not signed in"),
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
    hostOpenFile: (request) => failureResponse(request, "notAllowed", "Diff sidecar request was rejected"),
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
    ONE_FILE_PATCH,
    PICKER_OPTIONS,
  );
  await waitFor(
    () => Boolean(document.getElementById("repo-header")),
    "the repository header",
  );
  const header = document.getElementById("repo-header")!;
  // The header is the view's only top row: no toolbar, no jump select, and
  // exactly one copy of the pickers, in the header.
  expect(document.getElementById("toolbar")).toBeNull();
  expect(document.getElementById("jump-select")).toBeNull();
  expect(document.getElementById("jump-search-button")).toBeNull();
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
    "",
    PICKER_OPTIONS,
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
    ONE_FILE_PATCH,
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
    TWO_FILE_PATCH,
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
};

test("the header names a single repository as text and offers the picker only with a choice", async () => {
  // One repository (the docked panel follows the workspace): no picker, the
  // abbreviated path precedes the branch.
  const single: SidecarRequest[] = [];
  const singleDocument = await renderApp(
    { kind: "unstaged", repoRoot: "/Users/dev/src/widgets" },
    sidecarMock(single, ["worktree.write"]),
    ONE_FILE_PATCH,
    SINGLE_REPO_OPTIONS,
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
    ONE_FILE_PATCH,
    PICKER_OPTIONS,
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
    "",
    SINGLE_REPO_OPTIONS,
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
    "",
    PICKER_OPTIONS,
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
    ONE_FILE_PATCH,
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
    "",
    PICKER_OPTIONS,
  );
  expect(document.defaultView!.cmuxDiffViewer?.refresh() ?? false).toBe(false);
  await new Promise((resolve) => setTimeout(resolve, 20));
  expect(sessionOpens(requests)).toBe(1);
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
  // Repo actions, a separator, the view options, a separator, copy/refresh.
  for (const text of [
    "Discard all changes…",
    "Stage all",
    ...VIEW_OPTION_LABELS,
    "Copy git apply command",
    "Refresh",
  ]) {
    expect(findButton(document, text, "#repo-overflow-menu")).toBeTruthy();
  }
  expect(menu.querySelectorAll(".menu-separator")).toHaveLength(2);
  expect(menu.querySelectorAll(".menu-segment-controls .segment-button")).toHaveLength(3);
  const order = Array.from(menu.children).map((child) =>
    child.classList.contains("menu-separator")
      ? "|"
      : child.textContent?.trim() ?? "",
  );
  expect(order.indexOf("Stage all")).toBeLessThan(order.indexOf("|"));
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
    "",
    PICKER_OPTIONS,
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
