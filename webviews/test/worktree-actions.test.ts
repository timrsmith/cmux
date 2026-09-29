import { describe, expect, test } from "bun:test";
import {
  annotationsForItem,
  attachHunkActionAnnotations,
  withHunkActionAnnotations,
} from "../src/comments/annotations";
import { fileName } from "../src/diff-stream";
import {
  MAX_COMMIT_MESSAGE_BYTES,
  MAX_HUNK_ACTION_ANNOTATIONS_PER_FILE,
  MAX_PULL_REQUEST_BODY_BYTES,
  MAX_PULL_REQUEST_TITLE_BYTES,
  abbreviateHomePath,
  buildBulkRequest,
  buildCommitRequest,
  buildCreatePullRequestRequest,
  buildFileRequest,
  buildHunkRequest,
  buildOpenFileRequest,
  buildPushRequest,
  buildRepositoryStatusRequest,
  bulkStageActionForSource,
  commitAvailability,
  externalPullRequestURL,
  fileActionsForSource,
  forgeActionAvailability,
  forgeActionHintKey,
  hunkActionAnchor,
  hunkActionTargets,
  hunkRefFromPierreHunk,
  pullRequestLabelKeys,
  pullRequestStateLabelKey,
  repositoryHeaderModel,
  reviewDecisionLabelKey,
  validateCommitMessage,
  validatePullRequestDraft,
  worktreeErrorDetail,
  worktreeErrorLabelKey,
  worktreeErrorReloads,
  worktreeFileTarget,
  worktreeWriteAvailable,
} from "../src/worktree-actions";
import type { RepositoryStatus } from "../src/diff/generated/protocol";

const session = {
  sessionId: "01234567-89ab-cdef-0123-456789abcdef",
  capabilityToken: "0123456789abcdef",
};
const unstaged = { kind: "unstaged", repoRoot: "/tmp/repo" } as const;
const staged = { kind: "staged", repoRoot: "/tmp/repo" } as const;
const branch = {
  kind: "branch",
  repoRoot: "/tmp/repo",
  baseRef: "main",
} as const;
const patch = { kind: "patch", path: "/last-turn.patch" } as const;

describe("write action visibility by source kind", () => {
  test("only unstaged and staged sources get file actions", () => {
    expect(fileActionsForSource(unstaged)).toEqual(["stageFile", "revertFile"]);
    expect(fileActionsForSource(staged)).toEqual(["unstageFile", "revertFile"]);
    expect(fileActionsForSource(branch)).toEqual([]);
    expect(fileActionsForSource(patch)).toEqual([]);
    expect(fileActionsForSource(null)).toEqual([]);
  });

  test("commit is enabled for staged, hinted for unstaged, hidden otherwise", () => {
    expect(commitAvailability(staged)).toBe("enabled");
    expect(commitAvailability(unstaged)).toBe("stageAll");
    expect(commitAvailability(branch)).toBe("hidden");
    expect(commitAvailability(patch)).toBe("hidden");
  });

  test("write availability requires a typed session and the sidecar capability", () => {
    const capable = ["resource.stream", "worktree.write"];
    expect(worktreeWriteAvailable(unstaged, capable, true)).toBe(true);
    expect(worktreeWriteAvailable(staged, capable, true)).toBe(true);
    expect(worktreeWriteAvailable(branch, capable, true)).toBe(false);
    expect(worktreeWriteAvailable(patch, capable, true)).toBe(false);
    expect(worktreeWriteAvailable(unstaged, ["resource.stream"], true)).toBe(
      false,
    );
    expect(worktreeWriteAvailable(unstaged, null, true)).toBe(false);
    expect(worktreeWriteAvailable(unstaged, capable, false)).toBe(false);
  });
});

describe("hunk references", () => {
  test("map Pierre hunk ranges onto unified diff header ranges", () => {
    expect(
      hunkRefFromPierreHunk({
        additionStart: 11,
        additionCount: 3,
        deletionStart: 10,
        deletionCount: 2,
      }),
    ).toEqual({ oldStart: 10, oldCount: 2, newStart: 11, newCount: 3 });
  });

  test("anchor the action row under the hunk's last new-side line, or last deleted line", () => {
    expect(
      hunkActionAnchor({
        additionStart: 11,
        additionCount: 3,
        deletionStart: 10,
        deletionCount: 2,
      }),
    ).toEqual({ side: "additions", lineNumber: 13 });
    expect(
      hunkActionAnchor({
        additionStart: 0,
        additionCount: 0,
        deletionStart: 1,
        deletionCount: 4,
      }),
    ).toEqual({ side: "deletions", lineNumber: 4 });
    expect(
      hunkActionAnchor({
        additionStart: 0,
        additionCount: 0,
        deletionStart: 0,
        deletionCount: 0,
      }),
    ).toBeNull();
  });

  test("a hunk ending in a deletion-only group anchors on its last deleted line", () => {
    // `@@ -10,4 +11,2 @@`: two context lines, then two deletions and
    // nothing added after them. The additions side ends at line 12, above
    // the deleted lines Pierre renders last; the row belongs under those.
    const trailingDeletions = {
      additionStart: 11,
      additionCount: 2,
      deletionStart: 10,
      deletionCount: 4,
      hunkContent: [
        {
          type: "context",
          lines: 2,
          additionLineIndex: 0,
          deletionLineIndex: 0,
        },
        {
          type: "change",
          deletions: 2,
          additions: 0,
          deletionLineIndex: 2,
          additionLineIndex: 2,
        },
      ],
    } as const;
    expect(hunkActionAnchor(trailingDeletions)).toEqual({
      side: "deletions",
      lineNumber: 13,
    });
    // A change group with additions after its deletions still ends on the
    // additions side, as does trailing context.
    expect(
      hunkActionAnchor({
        ...trailingDeletions,
        hunkContent: [
          {
            type: "change",
            deletions: 2,
            additions: 1,
            deletionLineIndex: 0,
            additionLineIndex: 0,
          },
        ],
      }),
    ).toEqual({ side: "additions", lineNumber: 12 });
    expect(
      hunkActionAnchor({
        ...trailingDeletions,
        hunkContent: [
          {
            type: "change",
            deletions: 2,
            additions: 0,
            deletionLineIndex: 0,
            additionLineIndex: 0,
          },
          {
            type: "context",
            lines: 2,
            additionLineIndex: 0,
            deletionLineIndex: 2,
          },
        ],
      }),
    ).toEqual({ side: "additions", lineNumber: 12 });
    // Without content groups the header ranges alone decide.
    expect(
      hunkActionAnchor({ ...trailingDeletions, hunkContent: undefined }),
    ).toEqual({ side: "additions", lineNumber: 12 });
  });

  test("hunk action targets are capped per file and skip malformed hunks", () => {
    const hunks = [
      {
        additionStart: 1,
        additionCount: 2,
        deletionStart: 1,
        deletionCount: 1,
      },
      {
        additionStart: "x",
        additionCount: 2,
        deletionStart: 1,
        deletionCount: 1,
      },
      {
        additionStart: 20,
        additionCount: 1,
        deletionStart: 19,
        deletionCount: 3,
      },
    ];
    expect(
      hunkActionTargets({ hunks }).map((target) => [
        target.index,
        target.hunk,
        target.anchor,
      ]),
    ).toEqual([
      [
        0,
        { oldStart: 1, oldCount: 1, newStart: 1, newCount: 2 },
        { side: "additions", lineNumber: 2 },
      ],
      [
        2,
        { oldStart: 19, oldCount: 3, newStart: 20, newCount: 1 },
        { side: "additions", lineNumber: 20 },
      ],
    ]);
    const tooMany = Array.from(
      { length: MAX_HUNK_ACTION_ANNOTATIONS_PER_FILE + 1 },
      (_value, index) => ({
        additionStart: index * 10 + 1,
        additionCount: 1,
        deletionStart: index * 10 + 1,
        deletionCount: 1,
      }),
    );
    expect(hunkActionTargets({ hunks: tooMany })).toEqual([]);
    expect(hunkActionTargets({ hunks: [] })).toEqual([]);
    expect(hunkActionTargets(null)).toEqual([]);
  });

  test("hunk action targets are computed once per fileDiff object", () => {
    const fileDiff = {
      hunks: [
        {
          additionStart: 1,
          additionCount: 2,
          deletionStart: 1,
          deletionCount: 1,
        },
      ],
    };
    const first = hunkActionTargets(fileDiff);
    expect(first).toHaveLength(1);
    expect(hunkActionTargets(fileDiff)).toBe(first);
    expect(hunkActionTargets({ ...fileDiff })).not.toBe(first);
  });

  test("hunk action rows are attached at render time, outside the reducer annotations", () => {
    const item = {
      id: "story.txt",
      type: "diff",
      version: 2,
      annotations: [
        { side: "additions", lineNumber: 1, metadata: { kind: "draft" } },
      ],
      fileDiff: {
        name: "story.txt",
        hunks: [
          {
            additionStart: 1,
            additionCount: 3,
            deletionStart: 1,
            deletionCount: 2,
          },
        ],
      },
    } as any;
    // The reducer's own annotations never carry hunk rows.
    expect(annotationsForItem(item, [], null)).toEqual([]);
    const decorated = withHunkActionAnnotations(item);
    expect(decorated).not.toBe(item);
    expect(decorated.annotations).toEqual([
      { side: "additions", lineNumber: 1, metadata: { kind: "draft" } },
      {
        side: "additions",
        lineNumber: 3,
        metadata: {
          kind: "hunkActions",
          index: 0,
          hunk: { oldStart: 1, oldCount: 2, newStart: 1, newCount: 3 },
        },
      },
    ]);
    // A disjoint version range: the CodeView must see a change both when the
    // rows appear and when they go away, whatever the source version is.
    expect(decorated.version).toBe(-3);
    expect(item.version).toBe(2);
    // Same source item, same decorated object; the list itself is new.
    expect(withHunkActionAnnotations(item)).toBe(decorated);
    const list = attachHunkActionAnnotations([item]);
    expect(list[0]).toBe(decorated);
    expect(attachHunkActionAnnotations([item])).not.toBe(list);
    // Items without hunks or without a fileDiff pass through untouched.
    const hunkless = {
      id: "empty",
      type: "diff",
      fileDiff: { name: "e", hunks: [] },
    } as any;
    expect(withHunkActionAnnotations(hunkless)).toBe(hunkless);
    const fileless = { id: "none", type: "diff" } as any;
    expect(withHunkActionAnnotations(fileless)).toBe(fileless);
  });
});

describe("request envelopes", () => {
  test("file requests map the header action onto the sidecar method", () => {
    expect(
      buildFileRequest("stageFile", session, unstaged, { path: "src/a.ts" }),
    ).toEqual({
      method: "worktreeStageFile",
      params: { ...session, source: unstaged, path: "src/a.ts" },
    });
    expect(
      buildFileRequest("unstageFile", session, staged, { path: "src/a.ts" }),
    ).toMatchObject({ method: "worktreeUnstageFile" });
    expect(
      buildFileRequest("revertFile", session, staged, {
        path: "new.ts",
        previousPath: "old.ts",
      }),
    ).toEqual({
      method: "worktreeRevertFile",
      params: {
        ...session,
        source: staged,
        path: "new.ts",
        previousPath: "old.ts",
      },
    });
  });

  test("hunk and commit requests are typed for the sidecar", () => {
    const hunk = { oldStart: 1, oldCount: 2, newStart: 1, newCount: 3 };
    expect(
      buildHunkRequest(session, unstaged, { path: "src/a.ts" }, hunk),
    ).toEqual({
      method: "worktreeRevertHunk",
      params: { ...session, source: unstaged, path: "src/a.ts", hunk },
    });
    // A staged rename carries its origin so the sidecar re-reads both names.
    expect(
      buildHunkRequest(
        session,
        staged,
        { path: "new.ts", previousPath: "old.ts" },
        hunk,
      ),
    ).toEqual({
      method: "worktreeRevertHunk",
      params: {
        ...session,
        source: staged,
        path: "new.ts",
        previousPath: "old.ts",
        hunk,
      },
    });
    expect(buildCommitRequest(session, staged, "Fix it")).toEqual({
      method: "worktreeCommit",
      params: { ...session, source: staged, message: "Fix it" },
    });
  });

  test("file targets key the file the way comments do and keep the rename origin", () => {
    const rename = { name: "b.ts", prevName: "a.ts" };
    expect(worktreeFileTarget(rename)).toEqual({
      path: "b.ts",
      previousPath: "a.ts",
    });
    expect(worktreeFileTarget(rename)?.path).toBe(fileName(rename));
    expect(
      worktreeFileTarget({ name: "same.ts", prevName: "same.ts" }),
    ).toEqual({ path: "same.ts" });
    const deleted = { newName: "/dev/null", oldName: "gone.ts" };
    expect(worktreeFileTarget(deleted)).toEqual({ path: "gone.ts" });
    expect(fileName(deleted)).toBe("gone.ts");
    expect(fileName({ name: "" }, "fallback")).toBe("fallback");
    expect(worktreeFileTarget({})).toBeNull();
    expect(worktreeFileTarget(null)).toBeNull();
  });
});

describe("commit popover validation", () => {
  test("trims the message and rejects empty or oversized input", () => {
    expect(validateCommitMessage("  Add feature\n")).toEqual({
      ok: true,
      message: "Add feature",
    });
    expect(validateCommitMessage("   \n\t")).toEqual({
      ok: false,
      reason: "empty",
    });
    expect(
      validateCommitMessage("x".repeat(MAX_COMMIT_MESSAGE_BYTES)),
    ).toMatchObject({ ok: true });
    expect(
      validateCommitMessage("x".repeat(MAX_COMMIT_MESSAGE_BYTES + 1)),
    ).toEqual({ ok: false, reason: "tooLong" });
    // Multi-byte characters count in UTF-8 bytes, matching the sidecar.
    expect(
      validateCommitMessage("é".repeat(MAX_COMMIT_MESSAGE_BYTES / 2 + 1)),
    ).toEqual({ ok: false, reason: "tooLong" });
    // Four-byte characters: the code-unit fast path must not admit them.
    expect(
      validateCommitMessage("😀".repeat(MAX_COMMIT_MESSAGE_BYTES / 4 + 1)),
    ).toEqual({ ok: false, reason: "tooLong" });
    expect(
      validateCommitMessage("😀".repeat(MAX_COMMIT_MESSAGE_BYTES / 4)),
    ).toMatchObject({ ok: true });
  });

  test("error labels", () => {
    expect(worktreeErrorLabelKey("staleHunk")).toBe("hunkStale");
    expect(worktreeErrorLabelKey("conflict")).toBe("worktreeConflict");
    expect(worktreeErrorLabelKey("partialRevert")).toBe(
      "worktreePartialRevert",
    );
    expect(worktreeErrorLabelKey("nothingToCommit")).toBe("nothingToCommit");
    expect(worktreeErrorLabelKey("commitFailed")).toBe("commitFailed");
    expect(worktreeErrorLabelKey("invalidMessage")).toBe(
      "commitMessageInvalid",
    );
    expect(worktreeErrorLabelKey("notAllowed")).toBe("worktreeNotAllowed");
    expect(worktreeErrorLabelKey("somethingElse")).toBe("worktreeWriteFailed");
    expect(worktreeErrorLabelKey("constructor")).toBe("worktreeWriteFailed");
    expect(worktreeErrorLabelKey(undefined)).toBe("worktreeWriteFailed");

    expect(worktreeErrorReloads("staleHunk")).toBe(true);
    expect(worktreeErrorReloads("conflict")).toBe(true);
    expect(worktreeErrorReloads("partialRevert")).toBe(true);
    expect(worktreeErrorReloads("notAllowed")).toBe(false);
    expect(worktreeErrorReloads("commitFailed")).toBe(false);
  });

  test("a write reloads when the sidecar says the state may have changed", () => {
    // The sidecar sets the flag once a mutating Git child ran (a bulk
    // restore, `add -u`, or `rm` that exited non-zero, a commit after
    // staging) or when the diff had changed under the page; the code alone
    // decides nothing.
    for (const code of ["worktreeWriteFailed", "nothingToCommit", "commitFailed", undefined]) {
      expect(worktreeErrorReloads(code, true)).toBe(true);
      expect(worktreeErrorReloads(code, false)).toBe(false);
      expect(worktreeErrorReloads(code)).toBe(false);
    }
    // An older sidecar without the flag still reloads for the codes that
    // always meant a changed diff.
    for (const code of ["staleHunk", "conflict", "partialRevert"]) {
      expect(worktreeErrorReloads(code, false)).toBe(true);
    }
    // Refused before anything ran, or never delivered: the page is current.
    for (const code of ["notAllowed", "invalidMessage", "requestTimeout", "closed", "missingResult"]) {
      expect(worktreeErrorReloads(code, false)).toBe(false);
    }
  });
});

describe("bulk, push, status, and pull request envelopes", () => {
  const status: RepositoryStatus = {
    branch: "feat",
    detached: false,
    upstream: "origin/feat",
    ahead: 1,
    behind: 0,
    hostKind: "github",
    forgeCli: { available: true, authenticated: true },
  };

  test("session-wide commands carry only the session and its source", () => {
    for (const [action, method] of [
      ["discardAll", "worktreeDiscardAll"],
      ["stageAll", "worktreeStageAll"],
      ["unstageAll", "worktreeUnstageAll"],
    ] as const) {
      expect(buildBulkRequest(action, session, unstaged)).toEqual({
        method,
        params: { ...session, source: unstaged },
      });
    }
    expect(buildRepositoryStatusRequest(session, staged)).toEqual({
      method: "worktreeRepositoryStatus",
      params: { ...session, source: staged },
    });
    expect(bulkStageActionForSource(unstaged)).toBe("stageAll");
    expect(bulkStageActionForSource(staged)).toBe("unstageAll");
    expect(bulkStageActionForSource(branch)).toBeNull();
  });

  test("commit carries stageAll only when asked", () => {
    expect(buildCommitRequest(session, staged, "Fix it", false)).toEqual({
      method: "worktreeCommit",
      params: { ...session, source: staged, message: "Fix it" },
    });
    expect(buildCommitRequest(session, unstaged, "Fix it", true)).toEqual({
      method: "worktreeCommit",
      params: { ...session, source: unstaged, message: "Fix it", stageAll: true },
    });
  });

  test("push and create carry their options in the sidecar's shape", () => {
    expect(buildPushRequest(session, unstaged, false)).toEqual({
      method: "worktreePush",
      params: { ...session, source: unstaged },
    });
    expect(buildPushRequest(session, unstaged, true)).toEqual({
      method: "worktreePush",
      params: { ...session, source: unstaged, setUpstream: true },
    });
    expect(
      buildCreatePullRequestRequest(session, staged, {
        title: "Add widgets",
        body: "Body",
        draft: false,
        base: "  ",
      }),
    ).toEqual({
      method: "worktreeCreatePullRequest",
      params: { ...session, source: staged, title: "Add widgets", body: "Body" },
    });
    expect(
      buildCreatePullRequestRequest(session, staged, {
        title: "Add widgets",
        body: "",
        draft: true,
        base: "main",
      }),
    ).toEqual({
      method: "worktreeCreatePullRequest",
      params: {
        ...session,
        source: staged,
        title: "Add widgets",
        body: "",
        draft: true,
        base: "main",
      },
    });
    expect(buildOpenFileRequest(session.capabilityToken, { path: "src/a.ts", previousPath: "b" })).toEqual({
      method: "hostOpenFile",
      params: { capabilityToken: session.capabilityToken, path: "src/a.ts" },
    });
  });

  test("pull request drafts mirror the sidecar's title, body, and base checks", () => {
    expect(
      validatePullRequestDraft({ title: " Add widgets ", body: "b", draft: true, base: " main " }),
    ).toEqual({ ok: true, draft: { title: "Add widgets", body: "b", draft: true, base: "main" } });
    expect(validatePullRequestDraft({ title: "T", body: "", draft: false, base: "" })).toEqual({
      ok: true,
      draft: { title: "T", body: "", draft: false, base: undefined },
    });
    expect(validatePullRequestDraft({ title: "  ", body: "", draft: false })).toEqual({
      ok: false,
      reason: "emptyTitle",
    });
    expect(
      validatePullRequestDraft({ title: "x".repeat(MAX_PULL_REQUEST_TITLE_BYTES + 1), body: "", draft: false }),
    ).toEqual({ ok: false, reason: "titleTooLong" });
    expect(
      validatePullRequestDraft({ title: "é".repeat(MAX_PULL_REQUEST_TITLE_BYTES / 2 + 1), body: "", draft: false }),
    ).toEqual({ ok: false, reason: "titleTooLong" });
    expect(validatePullRequestDraft({ title: "a\nb", body: "", draft: false })).toEqual({
      ok: false,
      reason: "titleTooLong",
    });
    expect(
      validatePullRequestDraft({ title: "T", body: "b".repeat(MAX_PULL_REQUEST_BODY_BYTES + 1), draft: false }),
    ).toEqual({ ok: false, reason: "bodyTooLong" });
    for (const base of ["-x", "a b", "a..b", "a@{1}", "/x", "x/", "a?b", "a:b"]) {
      expect(validatePullRequestDraft({ title: "T", body: "", draft: false, base })).toEqual({
        ok: false,
        reason: "invalidBase",
      });
    }
  });

  test("new error codes map to their notices and keep the remote's detail", () => {
    expect(worktreeErrorLabelKey("detachedHead")).toBe("detachedHead");
    expect(worktreeErrorLabelKey("noUpstream")).toBe("pushNoUpstream");
    expect(worktreeErrorLabelKey("authRequired")).toBe("authRequired");
    expect(worktreeErrorLabelKey("pushRejected")).toBe("pushRejected");
    expect(worktreeErrorLabelKey("forgeCliMissing")).toBe("forgeCliMissing");
    expect(worktreeErrorLabelKey("forgeNotAuthenticated")).toBe("forgeNotAuthenticated");
    expect(worktreeErrorLabelKey("pullRequestExists")).toBe("pullRequestExists");
    expect(worktreeErrorLabelKey("pullRequestCreateFailed")).toBe("pullRequestCreateFailed");
    expect(worktreeErrorLabelKey("invalidTitle")).toBe("pullRequestTitleInvalid");
    expect(worktreeErrorLabelKey("invalidBody")).toBe("pullRequestBodyInvalid");
    expect(worktreeErrorLabelKey("invalidBase")).toBe("pullRequestBaseInvalid");
    expect(worktreeErrorDetail("pushRejected", "The remote rejected the push: hook declined")).toBe(
      "hook declined",
    );
    expect(
      worktreeErrorDetail("pullRequestExists", "A pull request already exists for this branch: https://x/pull/1"),
    ).toBe("https://x/pull/1");
    expect(worktreeErrorDetail("pushRejected", "The remote rejected the push")).toBeNull();
    expect(worktreeErrorDetail("authRequired", "Git could not authenticate: x")).toBeNull();
    expect(worktreeErrorDetail(undefined, "x: y")).toBeNull();
    for (const code of ["pushRejected", "noUpstream", "authRequired", "pullRequestExists"]) {
      expect(worktreeErrorReloads(code)).toBe(false);
    }
  });

  test("the header model abbreviates the home directory and reads the streamed totals", () => {
    expect(abbreviateHomePath("/Users/dev/src/widgets")).toBe("~/src/widgets");
    expect(abbreviateHomePath("/home/dev")).toBe("~");
    expect(abbreviateHomePath("/Users/dev")).toBe("~");
    expect(abbreviateHomePath("/Usersx/dev/src")).toBe("/Usersx/dev/src");
    expect(abbreviateHomePath("/tmp/repo")).toBe("/tmp/repo");
    expect(abbreviateHomePath("/Users")).toBe("/Users");
    const home = { kind: "unstaged", repoRoot: "/Users/dev/widgets" } as const;
    expect(
      repositoryHeaderModel(home, status, {
        addedLines: 12,
        deletedLines: 3,
        fileCount: 4,
        totalLinesOfCode: 100,
      }),
    ).toEqual({
      repoLabel: "~/widgets",
      branch: "feat",
      detached: false,
      upstream: "origin/feat",
      ahead: 1,
      behind: 0,
      fileCount: 4,
      additions: 12,
      deletions: 3,
    });
    // Before the stream and the status arrive everything reads as zero.
    expect(repositoryHeaderModel(unstaged, null, null)).toEqual({
      repoLabel: "/tmp/repo",
      branch: null,
      detached: false,
      upstream: null,
      ahead: 0,
      behind: 0,
      fileCount: 0,
      additions: 0,
      deletions: 0,
    });
  });

  test("forge availability follows the host kind, the CLI, and the sign-in state", () => {
    expect(forgeActionAvailability(null)).toEqual({ push: "unknown", createPullRequest: "unknown" });
    expect(forgeActionAvailability(status)).toEqual({ push: "enabled", createPullRequest: "enabled" });
    expect(forgeActionAvailability({ ...status, detached: true })).toEqual({
      push: "detached",
      createPullRequest: "detached",
    });
    expect(forgeActionAvailability({ ...status, hostKind: "none" })).toEqual({
      push: "noRemote",
      createPullRequest: "noRemote",
    });
    expect(forgeActionAvailability({ ...status, hostKind: "other" })).toEqual({
      push: "enabled",
      createPullRequest: "noForge",
    });
    expect(
      forgeActionAvailability({
        ...status,
        forgeCli: { available: false, authenticated: false },
      }),
    ).toEqual({ push: "enabled", createPullRequest: "cliMissing" });
    expect(
      forgeActionAvailability({
        ...status,
        hostKind: "gitlab",
        forgeCli: { available: true, authenticated: false },
      }),
    ).toEqual({ push: "enabled", createPullRequest: "notAuthenticated" });
    expect(forgeActionHintKey("enabled")).toBeNull();
    expect(forgeActionHintKey("unknown")).toBeNull();
    expect(forgeActionHintKey("detached")).toBe("detachedHead");
    expect(forgeActionHintKey("noRemote")).toBe("noRemote");
    expect(forgeActionHintKey("noForge")).toBe("forgeUnavailable");
    expect(forgeActionHintKey("cliMissing")).toBe("forgeCliMissing");
    expect(forgeActionHintKey("notAuthenticated")).toBe("forgeNotAuthenticated");
  });

  test("pull request wording, states, reviews, and links", () => {
    expect(pullRequestLabelKeys("github").create).toBe("createPullRequest");
    expect(pullRequestLabelKeys("other").submit).toBe("createPullRequestSubmit");
    expect(pullRequestLabelKeys(null).open).toBe("openPullRequest");
    expect(pullRequestLabelKeys("gitlab")).toEqual({
      create: "createMergeRequest",
      dialog: "createMergeRequestDialog",
      submit: "createMergeRequestSubmit",
      open: "openMergeRequest",
    });
    expect(pullRequestStateLabelKey({ state: "open", isDraft: false })).toBe("prStateOpen");
    expect(pullRequestStateLabelKey({ state: "open", isDraft: true })).toBe("prStateDraft");
    expect(pullRequestStateLabelKey({ state: "merged", isDraft: true })).toBe("prStateMerged");
    expect(pullRequestStateLabelKey({ state: "closed", isDraft: false })).toBe("prStateClosed");
    expect(reviewDecisionLabelKey("approved")).toBe("reviewApproved");
    expect(reviewDecisionLabelKey("changes_requested")).toBe("reviewChangesRequested");
    expect(reviewDecisionLabelKey("review_required")).toBe("reviewRequired");
    expect(reviewDecisionLabelKey(undefined)).toBeNull();
    expect(reviewDecisionLabelKey("")).toBeNull();
    expect(externalPullRequestURL("https://github.com/acme/widgets/pull/42")).toBe(
      "https://github.com/acme/widgets/pull/42",
    );
    expect(externalPullRequestURL("http://gitlab.internal/mr/1")).toBe("http://gitlab.internal/mr/1");
    expect(externalPullRequestURL("javascript:alert(1)")).toBeNull();
    expect(externalPullRequestURL("cmux-diff-viewer://token/x")).toBeNull();
    expect(externalPullRequestURL("not a url")).toBeNull();
    expect(externalPullRequestURL(undefined)).toBeNull();
  });
});
