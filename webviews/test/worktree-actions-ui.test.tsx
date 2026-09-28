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
  sidecarMock,
  type SidecarRequest,
} from "./support/sidecar-mock";

registerDomCleanup();

const label = createDiffViewerLabelResolver(undefined);
const viewerURL = `cmux-diff-viewer://${token}/viewer.html`;

/** Mounts the App on a typed WebKit session against `mock`, then waits for the (empty) diff. */
async function renderApp(source: any, mock: ReturnType<typeof sidecarMock>) {
  const dom = mountDom(viewerURL, emptyFetch);
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
  await waitFor(
    () => dom.window.document.body.dataset.streamFileCount === "0",
    "the empty diff to stream",
  );
  return dom.window.document;
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
      source: { kind: "staged", repoRoot: "/tmp/repo" },
      capabilities: ["worktree.write"],
      expected: "enabled",
    },
    {
      source: { kind: "unstaged", repoRoot: "/tmp/repo" },
      capabilities: ["worktree.write"],
      expected: "requiresStaged",
    },
    {
      source: { kind: "branch", repoRoot: "/tmp/repo", baseRef: "main" },
      capabilities: ["worktree.write"],
      expected: "absent",
    },
    {
      source: { kind: "staged", repoRoot: "/tmp/repo" },
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
    expect(
      requests.some((request) => request.method === "protocolHandshake"),
    ).toBe(true);
    await new Promise((resolve) => setTimeout(resolve, 0));
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
    document.getElementById("options-button")?.click();
    await waitFor(
      () => Boolean(document.getElementById("options-menu")),
      "the options menu",
    );
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
    { kind: "staged", repoRoot: "/tmp/repo" },
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
  expect(
    requests.filter((request) => request.method === "worktreeCommit"),
  ).toHaveLength(0);
  setTextareaValue(textarea!, "  Ship it\n");
  await waitFor(
    () => submit()?.disabled === false,
    "the submit button to enable",
  );
  click(submit());
  await waitFor(
    () =>
      requests.filter((request) => request.method === "worktreeCommit")
        .length === 1,
    "the commit request",
  );
  const commit = requests.find(
    (request) => request.method === "worktreeCommit",
  );
  expect(commit?.params).toEqual({
    sessionId,
    capabilityToken: token,
    source: { kind: "staged", repoRoot: "/tmp/repo" },
    message: "Ship it",
  });
  // Success reopens the session in place (no page reload) and reports the hash.
  await waitFor(
    () =>
      requests.filter((request) => request.method === "sessionOpen").length ===
      2,
    "the session to reopen",
  );
  await waitFor(
    () =>
      document.getElementById("worktree-notice")?.textContent ===
      "Committed 0123456789",
    "the committed notice",
  );
  expect(document.getElementById("commit-popover")).toBeNull();
  expect(
    requests.filter((request) => request.method === "sessionOpen")[1].params
      .source,
  ).toEqual({ kind: "staged", repoRoot: "/tmp/repo" });
});

test("an oversized commit message is flagged on submit and never sent", async () => {
  const requests: SidecarRequest[] = [];
  const document = await renderApp(
    { kind: "staged", repoRoot: "/tmp/repo" },
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
  expect(
    requests.filter((request) => request.method === "worktreeCommit"),
  ).toHaveLength(0);
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
    { kind: "staged", repoRoot: "/tmp/repo" },
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
  expect(
    requests.filter((request) => request.method === "sessionOpen"),
  ).toHaveLength(1);
});
