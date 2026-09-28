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
  buildCommitRequest,
  buildFileRequest,
  buildHunkRequest,
  commitAvailability,
  fileActionsForSource,
  hunkActionAnchor,
  hunkActionTargets,
  hunkRefFromPierreHunk,
  validateCommitMessage,
  worktreeErrorLabelKey,
  worktreeErrorReloads,
  worktreeFileTarget,
  worktreeWriteAvailable,
} from "../src/worktree-actions";

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
    expect(commitAvailability(unstaged)).toBe("requiresStaged");
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
        { additionStart: 1, additionCount: 2, deletionStart: 1, deletionCount: 1 },
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
    const hunkless = { id: "empty", type: "diff", fileDiff: { name: "e", hunks: [] } } as any;
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
    expect(worktreeErrorReloads("notAllowed")).toBe(false);
  });
});
