import { expect, test } from "bun:test";
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
  MOCK_SESSION_ID as sessionId,
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

/**
 * Mounts the App on a typed WebKit session against `mock`. With a `patch`,
 * every patch fetch streams it and the render waits for its file header
 * actions; otherwise the diff is empty and the render waits for that.
 */
async function renderApp(
  source: any,
  mock: ReturnType<typeof sidecarMock>,
  patch = "",
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

test("commit button follows the source kind and the sidecar capability", async () => {
  const cases: Array<{
    source: any;
    capabilities: string[];
    expected: "enabled" | "requiresStaged" | "absent";
  }> = [
    {
      source: stagedSource,
      capabilities: ["worktree.write"],
      expected: "enabled",
    },
    {
      source: unstagedSource,
      capabilities: ["worktree.write"],
      expected: "requiresStaged",
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
    // The options menu renders after the handshake settled either way.
    document.getElementById("options-button")?.click();
    await waitFor(
      () => Boolean(document.getElementById("options-menu")),
      "the options menu",
    );
    const button = document.getElementById(
      "commit-button",
    ) as HTMLButtonElement | null;
    if (expected === "absent") {
      expect(button).toBeNull();
    } else {
      expect(button).toBeTruthy();
      expect(button?.dataset.availability).toBe(expected);
      expect(button?.disabled).toBe(expected !== "enabled");
      if (expected === "requiresStaged") {
        expect(button?.title).toBe("Stage changes to commit them.");
      }
    }
    // The "..." menu always carries the canonical copy of the commit action.
    const menuCommit = findButton(document, "Commit changes");
    if (expected === "absent") {
      expect(menuCommit).toBeUndefined();
    } else {
      expect(menuCommit?.disabled).toBe(expected !== "enabled");
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
  document.getElementById("options-button")?.click();
  await waitFor(
    () => Boolean(findButton(document, "Collapse all diffs")),
    "the collapse-all option",
  );
  click(findButton(document, "Collapse all diffs"));
  // A collapsed file keeps its header (and header actions) but renders no
  // code.
  await waitFor(() => renderedCodeBlocks(document) === 0, "the file to collapse");
  expect(document.querySelectorAll(".worktree-action")).toHaveLength(2);
  click(headerAction(document, "stageFile"));
  await waitForReload(document, requests);
  // The option survived the reset, so the re-streamed file arrives collapsed
  // (no per-item bookkeeping needed).
  expect(document.querySelectorAll(".worktree-action")).toHaveLength(2);
  expect(renderedCodeBlocks(document)).toBe(0);
  expect(document.body.dataset.streamFileCount).toBe("1");
  expect(findButton(document, "Expand all diffs")).toBeTruthy();
});
