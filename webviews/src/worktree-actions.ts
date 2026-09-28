// Pure decision and request-building layer for the diff viewer's write
// actions (revert / stage / unstage / revert hunk / commit). The React layer
// only renders what these helpers return, so visibility by source kind, hunk
// identification, and the request envelopes are unit-testable without a DOM.

import type { DiffCommand } from "./diff/transport";
import type {
  DiffSource,
  HunkRef,
  WorktreeCommitRequest,
  WorktreeFileRequest,
  WorktreeHunkRequest,
} from "./diff/generated/protocol";
import { filePath, previousFilePath } from "./diff-stream";
import type { DiffViewerLabelKey } from "./labels";

/** Handshake capability the sidecar advertises when write commands exist. */
export const WORKTREE_WRITE_CAPABILITY = "worktree.write";

/** Matches the sidecar's `MAX_COMMIT_MESSAGE_BYTES`. */
export const MAX_COMMIT_MESSAGE_BYTES = 64 * 1024;

/**
 * Per-file cap on hunk action rows. Each row is one extra slotted annotation
 * element inside a rendered file, so a pathological file with thousands of
 * hunks does not multiply the DOM the virtualizer has to lay out.
 */
export const MAX_HUNK_ACTION_ANNOTATIONS_PER_FILE = 200;

export type WritableDiffSource = Extract<
  DiffSource,
  { kind: "unstaged" | "staged" }
>;

export type FileWriteAction = "stageFile" | "unstageFile" | "revertFile";

export type CommitAvailability = "enabled" | "requiresStaged" | "hidden";

export type WorktreeSession = {
  sessionId: string;
  capabilityToken: string;
};

export type WorktreeFileTarget = {
  path: string;
  previousPath?: string;
};

/** A Pierre `Hunk` reduced to the header ranges the sidecar matches on. */
export type PierreHunkRanges = {
  additionStart: number;
  additionCount: number;
  deletionStart: number;
  deletionCount: number;
};

export type HunkActionAnchor = {
  side: "additions" | "deletions";
  lineNumber: number;
};

export type HunkActionTarget = {
  index: number;
  hunk: HunkRef;
  anchor: HunkActionAnchor;
};

const FILE_ACTION_METHOD: Record<
  FileWriteAction,
  "worktreeRevertFile" | "worktreeStageFile" | "worktreeUnstageFile"
> = {
  revertFile: "worktreeRevertFile",
  stageFile: "worktreeStageFile",
  unstageFile: "worktreeUnstageFile",
};

export function writableDiffSource(
  source: DiffSource | null | undefined,
): WritableDiffSource | null {
  if (source == null) {
    return null;
  }
  return source.kind === "unstaged" || source.kind === "staged" ? source : null;
}

/**
 * Write actions exist only for repository-backed working-tree sources, over a
 * typed transport, on a sidecar that advertised the capability. Patch and
 * branch sources never get them, whatever the sidecar supports.
 */
export function worktreeWriteAvailable(
  source: DiffSource | null | undefined,
  capabilities: readonly string[] | null | undefined,
  hasTypedSession: boolean,
): boolean {
  return (
    hasTypedSession &&
    writableDiffSource(source) != null &&
    Array.isArray(capabilities) &&
    capabilities.includes(WORKTREE_WRITE_CAPABILITY)
  );
}

/** Header buttons per source kind, in render order. */
export function fileActionsForSource(
  source: DiffSource | null | undefined,
): FileWriteAction[] {
  switch (writableDiffSource(source)?.kind) {
    case "unstaged":
      return ["stageFile", "revertFile"];
    case "staged":
      return ["unstageFile", "revertFile"];
    default:
      return [];
  }
}

/** Commits only ever run against the index, so only a staged view offers it. */
export function commitAvailability(
  source: DiffSource | null | undefined,
): CommitAvailability {
  const writable = writableDiffSource(source);
  if (writable == null) {
    return "hidden";
  }
  return writable.kind === "staged" ? "enabled" : "requiresStaged";
}

/**
 * Resolves the repository-relative target of a file diff, keyed the same way
 * comments key their file (`fileName`). Renames carry both names so stage /
 * unstage / revert can act on the pair; the sidecar validates the paths again
 * before touching Git.
 */
export function worktreeFileTarget(fileDiff: any): WorktreeFileTarget | null {
  if (fileDiff == null || typeof fileDiff !== "object") {
    return null;
  }
  const path = filePath(fileDiff);
  if (path == null) {
    return null;
  }
  const previous = previousFilePath(fileDiff);
  return previous != null && previous !== path
    ? { path, previousPath: previous }
    : { path };
}

/** `@@ -old,count +new,count @@`: deletions describe the old side, additions the new. */
export function hunkRefFromPierreHunk(hunk: PierreHunkRanges): HunkRef {
  return {
    oldStart: hunk.deletionStart,
    oldCount: hunk.deletionCount,
    newStart: hunk.additionStart,
    newCount: hunk.additionCount,
  };
}

/**
 * Anchors a hunk's action row under the hunk's last line. Additions-side
 * numbering covers context and added lines; a hunk with no new-file lines
 * (a pure deletion at end of file) anchors on its last deleted line instead.
 */
export function hunkActionAnchor(
  hunk: PierreHunkRanges,
): HunkActionAnchor | null {
  if (hunk.additionCount > 0) {
    return {
      side: "additions",
      lineNumber: hunk.additionStart + hunk.additionCount - 1,
    };
  }
  if (hunk.deletionCount > 0) {
    return {
      side: "deletions",
      lineNumber: hunk.deletionStart + hunk.deletionCount - 1,
    };
  }
  return null;
}

// A fileDiff never changes once parsed, so its targets are computed once per
// object however often the item around it is re-annotated.
const hunkActionTargetsByFileDiff = new WeakMap<object, HunkActionTarget[]>();

/** Hunks eligible for action rows, or an empty list past the per-file cap. */
export function hunkActionTargets(fileDiff: any): HunkActionTarget[] {
  if (fileDiff == null || typeof fileDiff !== "object") {
    return [];
  }
  const cached = hunkActionTargetsByFileDiff.get(fileDiff);
  if (cached != null) {
    return cached;
  }
  const targets = computeHunkActionTargets(fileDiff);
  hunkActionTargetsByFileDiff.set(fileDiff, targets);
  return targets;
}

function computeHunkActionTargets(fileDiff: any): HunkActionTarget[] {
  const hunks = Array.isArray(fileDiff.hunks) ? fileDiff.hunks : [];
  if (
    hunks.length === 0 ||
    hunks.length > MAX_HUNK_ACTION_ANNOTATIONS_PER_FILE
  ) {
    return [];
  }
  const targets: HunkActionTarget[] = [];
  hunks.forEach((hunk: unknown, index: number) => {
    if (!isHunkRanges(hunk)) {
      return;
    }
    const anchor = hunkActionAnchor(hunk);
    if (anchor != null) {
      targets.push({ index, hunk: hunkRefFromPierreHunk(hunk), anchor });
    }
  });
  return targets;
}

function isHunkRanges(value: unknown): value is PierreHunkRanges {
  if (value == null || typeof value !== "object") {
    return false;
  }
  const hunk = value as Record<string, unknown>;
  return [
    hunk.additionStart,
    hunk.additionCount,
    hunk.deletionStart,
    hunk.deletionCount,
  ].every(
    (field) =>
      typeof field === "number" && Number.isInteger(field) && field >= 0,
  );
}

export function buildFileRequest(
  action: FileWriteAction,
  session: WorktreeSession,
  source: WritableDiffSource,
  target: WorktreeFileTarget,
): DiffCommand {
  const params: WorktreeFileRequest = {
    sessionId: session.sessionId,
    capabilityToken: session.capabilityToken,
    source,
    path: target.path,
  };
  if (target.previousPath != null) {
    params.previousPath = target.previousPath;
  }
  return { method: FILE_ACTION_METHOD[action], params };
}

/**
 * The rename origin rides along so the sidecar re-reads a staged rename with
 * both names in scope; without it Git would see a plain addition and the
 * hunk would never match.
 */
export function buildHunkRequest(
  session: WorktreeSession,
  source: WritableDiffSource,
  target: WorktreeFileTarget,
  hunk: HunkRef,
): DiffCommand {
  const params: WorktreeHunkRequest = {
    sessionId: session.sessionId,
    capabilityToken: session.capabilityToken,
    source,
    path: target.path,
    hunk,
  };
  if (target.previousPath != null) {
    params.previousPath = target.previousPath;
  }
  return { method: "worktreeRevertHunk", params };
}

export function buildCommitRequest(
  session: WorktreeSession,
  source: WritableDiffSource,
  message: string,
): DiffCommand {
  const params: WorktreeCommitRequest = {
    sessionId: session.sessionId,
    capabilityToken: session.capabilityToken,
    source,
    message,
  };
  return { method: "worktreeCommit", params };
}

export type CommitMessageValidation =
  { ok: true; message: string } | { ok: false; reason: "empty" | "tooLong" };

/**
 * Mirrors the sidecar: trimmed, non-empty, at most 64 KiB of UTF-8. A UTF-16
 * code unit encodes to at most three bytes, so short messages skip the
 * encode entirely.
 */
export function validateCommitMessage(raw: string): CommitMessageValidation {
  const message = raw.trim();
  if (message === "") {
    return { ok: false, reason: "empty" };
  }
  if (
    message.length * 3 > MAX_COMMIT_MESSAGE_BYTES &&
    new TextEncoder().encode(message).length > MAX_COMMIT_MESSAGE_BYTES
  ) {
    return { ok: false, reason: "tooLong" };
  }
  return { ok: true, message };
}

const WORKTREE_ERROR_LABEL: Record<string, DiffViewerLabelKey> = {
  staleHunk: "hunkStale",
  conflict: "worktreeConflict",
  nothingToCommit: "nothingToCommit",
  commitFailed: "commitFailed",
  invalidMessage: "commitMessageInvalid",
  notAllowed: "worktreeNotAllowed",
};

/** Maps sidecar error codes to the localized notice shown after a failed write. */
export function worktreeErrorLabelKey(
  code: string | undefined,
): DiffViewerLabelKey {
  if (code != null && Object.hasOwn(WORKTREE_ERROR_LABEL, code)) {
    return WORKTREE_ERROR_LABEL[code];
  }
  return "worktreeWriteFailed";
}


/** Whether a failed write left the on-disk state ahead of the rendered diff. */
export function worktreeErrorReloads(code: string | undefined): boolean {
  return code === "staleHunk" || code === "conflict";
}
