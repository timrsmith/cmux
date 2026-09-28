// Pure decision and request-building layer for the diff viewer's write
// actions (revert / stage / unstage / revert hunk / commit / bulk actions /
// push / pull requests). The React layer only renders what these helpers
// return, so visibility by source kind, hunk identification, forge
// availability, and the request envelopes are unit-testable without a DOM.

import type { FileDiffMetadata, Hunk } from "@pierre/diffs";
import type { DiffCommand, HostCommand } from "./diff/transport";
import type {
  DiffSource,
  HunkRef,
  PullRequestSummary,
  RepositoryHostKind,
  RepositoryStatus,
  WorktreeCommitRequest,
  WorktreeCreatePullRequestRequest,
  WorktreeFileRequest,
  WorktreeHunkRequest,
  WorktreePushRequest,
  WorktreeSessionRequest,
} from "./diff/generated/protocol";
import { filePath, previousFilePath, type DiffStats } from "./diff-stream";
import type { DiffViewerLabelKey } from "./labels";

/** Handshake capability the sidecar advertises when write commands exist. */
export const WORKTREE_WRITE_CAPABILITY = "worktree.write";

/** Matches the sidecar's `MAX_COMMIT_MESSAGE_BYTES`. */
export const MAX_COMMIT_MESSAGE_BYTES = 64 * 1024;

/** Match the sidecar's `MAX_PULL_REQUEST_TITLE_BYTES` / `_BODY_BYTES`. */
export const MAX_PULL_REQUEST_TITLE_BYTES = 256;
export const MAX_PULL_REQUEST_BODY_BYTES = 64 * 1024;

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

/** Whole-session write actions offered from the header's overflow menu. */
export type BulkWriteAction = "discardAll" | "stageAll" | "unstageAll";

/**
 * `enabled`: the view is the index, a commit records it as is. `stageAll`:
 * the view is the working tree, so the popover offers "stage all and commit"
 * (one sidecar action). `hidden`: no commit control at all.
 */
export type CommitAvailability = "enabled" | "stageAll" | "hidden";

export type WorktreeSession = {
  sessionId: string;
  capabilityToken: string;
};

export type WorktreeFileTarget = {
  path: string;
  previousPath?: string;
};

/**
 * A Pierre `Hunk` reduced to the header ranges the sidecar matches on, plus
 * (when known) its content groups, which decide where the action row sits.
 */
export type PierreHunkRanges = Pick<
  Hunk,
  "additionStart" | "additionCount" | "deletionStart" | "deletionCount"
> & {
  hunkContent?: ReadonlyArray<Hunk["hunkContent"][number]>;
};

/**
 * The slice of a file diff the write actions read: Pierre's metadata plus
 * the git-parsed side names `filePath` falls back to. Parsed diffs from the
 * stream carry every field; tests and defensive callers may pass less, and
 * anything without a usable name has no target.
 */
export type WorktreeFileDiff = Partial<
  Pick<FileDiffMetadata, "name" | "prevName">
> & {
  /** Checked for shape at runtime (`isHunkRanges`), so anything array-like is accepted. */
  hunks?: readonly unknown[];
  newName?: string;
  oldName?: string;
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

const BULK_ACTION_METHOD: Record<
  BulkWriteAction,
  "worktreeDiscardAll" | "worktreeStageAll" | "worktreeUnstageAll"
> = {
  discardAll: "worktreeDiscardAll",
  stageAll: "worktreeStageAll",
  unstageAll: "worktreeUnstageAll",
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

/** The whole-session counterpart of the per-file stage / unstage button. */
export function bulkStageActionForSource(
  source: DiffSource | null | undefined,
): Extract<BulkWriteAction, "stageAll" | "unstageAll"> | null {
  switch (writableDiffSource(source)?.kind) {
    case "unstaged":
      return "stageAll";
    case "staged":
      return "unstageAll";
    default:
      return null;
  }
}

/**
 * Commits only ever record the index. A staged view commits as is; an
 * unstaged view offers to stage every tracked change first.
 */
export function commitAvailability(
  source: DiffSource | null | undefined,
): CommitAvailability {
  const writable = writableDiffSource(source);
  if (writable == null) {
    return "hidden";
  }
  return writable.kind === "staged" ? "enabled" : "stageAll";
}

/**
 * Resolves the repository-relative target of a file diff, keyed the same way
 * comments key their file (`fileName`). Renames carry both names so stage /
 * unstage / revert can act on the pair; the sidecar validates the paths again
 * before touching Git.
 */
export function worktreeFileTarget(
  fileDiff: WorktreeFileDiff | null | undefined,
): WorktreeFileTarget | null {
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
 * Anchors a hunk's action row under the hunk's last rendered line. Pierre
 * lays a change group out deletions first, then additions, so a hunk whose
 * last group is deletions only ends on the deletions side and the row must
 * anchor there to render under the hunk rather than above its tail.
 * Otherwise the additions side (context and added lines) ends the hunk; a
 * hunk with no new-file lines at all anchors on its last deleted line.
 */
export function hunkActionAnchor(
  hunk: PierreHunkRanges,
): HunkActionAnchor | null {
  const last = hunk.hunkContent?.at(-1);
  const endsWithDeletions =
    last?.type === "change" && last.additions === 0 && last.deletions > 0;
  if (hunk.additionCount > 0 && !endsWithDeletions) {
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
export function hunkActionTargets(
  fileDiff: WorktreeFileDiff | null | undefined,
): HunkActionTarget[] {
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

function computeHunkActionTargets(
  fileDiff: WorktreeFileDiff,
): HunkActionTarget[] {
  const hunks: readonly unknown[] = Array.isArray(fileDiff.hunks)
    ? fileDiff.hunks
    : [];
  if (
    hunks.length === 0 ||
    hunks.length > MAX_HUNK_ACTION_ANNOTATIONS_PER_FILE
  ) {
    return [];
  }
  const targets: HunkActionTarget[] = [];
  hunks.forEach((hunk, index) => {
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

/**
 * `stageAll` rides along only when set, so a staged view's commit envelope is
 * unchanged from before the option existed.
 */
export function buildCommitRequest(
  session: WorktreeSession,
  source: WritableDiffSource,
  message: string,
  stageAll = false,
): DiffCommand {
  const params: WorktreeCommitRequest = {
    sessionId: session.sessionId,
    capabilityToken: session.capabilityToken,
    source,
    message,
  };
  if (stageAll) {
    params.stageAll = true;
  }
  return { method: "worktreeCommit", params };
}

function sessionParams(
  session: WorktreeSession,
  source: WritableDiffSource,
): WorktreeSessionRequest {
  return {
    sessionId: session.sessionId,
    capabilityToken: session.capabilityToken,
    source,
  };
}

export function buildBulkRequest(
  action: BulkWriteAction,
  session: WorktreeSession,
  source: WritableDiffSource,
): DiffCommand {
  return {
    method: BULK_ACTION_METHOD[action],
    params: sessionParams(session, source),
  };
}

export function buildRepositoryStatusRequest(
  session: WorktreeSession,
  source: WritableDiffSource,
): DiffCommand {
  return {
    method: "worktreeRepositoryStatus",
    params: sessionParams(session, source),
  };
}

export function buildPushRequest(
  session: WorktreeSession,
  source: WritableDiffSource,
  setUpstream: boolean,
): DiffCommand {
  const params: WorktreePushRequest = sessionParams(session, source);
  if (setUpstream) {
    params.setUpstream = true;
  }
  return { method: "worktreePush", params };
}

export type PullRequestDraft = {
  title: string;
  body: string;
  draft: boolean;
  base?: string;
};

export function buildCreatePullRequestRequest(
  session: WorktreeSession,
  source: WritableDiffSource,
  draft: PullRequestDraft,
): DiffCommand {
  const params: WorktreeCreatePullRequestRequest = {
    ...sessionParams(session, source),
    title: draft.title,
    body: draft.body,
  };
  if (draft.draft) {
    params.draft = true;
  }
  const base = draft.base?.trim();
  if (base) {
    params.base = base;
  }
  return { method: "worktreeCreatePullRequest", params };
}

/**
 * Opens a repository file in the hosting cmux workspace. Handled natively by
 * the host bridge, never forwarded to the sidecar; the host re-validates the
 * path against the token's repositories.
 */
export function buildOpenFileRequest(
  capabilityToken: string,
  target: WorktreeFileTarget,
): HostCommand {
  return {
    method: "hostOpenFile",
    params: { capabilityToken, path: target.path },
  };
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
  if (exceedsUTF8Bytes(message, MAX_COMMIT_MESSAGE_BYTES)) {
    return { ok: false, reason: "tooLong" };
  }
  return { ok: true, message };
}

export type PullRequestValidation =
  | { ok: true; draft: PullRequestDraft }
  | {
      ok: false;
      reason: "emptyTitle" | "titleTooLong" | "bodyTooLong" | "invalidBase";
    };

/** Mirrors the sidecar's title (one line, 256 bytes), body (64 KiB) and base checks. */
export function validatePullRequestDraft(
  input: PullRequestDraft,
): PullRequestValidation {
  const title = input.title.trim();
  if (title === "") {
    return { ok: false, reason: "emptyTitle" };
  }
  if (
    /[\r\n]/.test(title) ||
    exceedsUTF8Bytes(title, MAX_PULL_REQUEST_TITLE_BYTES)
  ) {
    return { ok: false, reason: "titleTooLong" };
  }
  if (exceedsUTF8Bytes(input.body, MAX_PULL_REQUEST_BODY_BYTES)) {
    return { ok: false, reason: "bodyTooLong" };
  }
  const base = input.base?.trim() ?? "";
  if (base !== "" && !isPlausibleRefName(base)) {
    return { ok: false, reason: "invalidBase" };
  }
  return {
    ok: true,
    draft: {
      title,
      body: input.body,
      draft: input.draft,
      base: base === "" ? undefined : base,
    },
  };
}

function isPlausibleRefName(name: string): boolean {
  return (
    name.length <= 256 &&
    !name.startsWith("-") &&
    !name.startsWith("/") &&
    !name.endsWith("/") &&
    !name.includes("..") &&
    !name.includes("@{") &&
    !/[\s~^:?*[\\]/.test(name)
  );
}

function exceedsUTF8Bytes(text: string, limit: number): boolean {
  return (
    text.length * 3 > limit && new TextEncoder().encode(text).length > limit
  );
}

const WORKTREE_ERROR_LABEL: Record<string, DiffViewerLabelKey> = {
  staleHunk: "hunkStale",
  conflict: "worktreeConflict",
  partialRevert: "worktreePartialRevert",
  nothingToCommit: "nothingToCommit",
  commitFailed: "commitFailed",
  invalidMessage: "commitMessageInvalid",
  notAllowed: "worktreeNotAllowed",
  detachedHead: "detachedHead",
  noUpstream: "pushNoUpstream",
  authRequired: "authRequired",
  pushRejected: "pushRejected",
  forgeCliMissing: "forgeCliMissing",
  forgeNotAuthenticated: "forgeNotAuthenticated",
  pullRequestExists: "pullRequestExists",
  pullRequestCreateFailed: "pullRequestCreateFailed",
  invalidTitle: "pullRequestTitleInvalid",
  invalidBody: "pullRequestBodyInvalid",
  invalidBase: "pullRequestBaseInvalid",
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

/** Error codes whose sidecar message carries a detail worth showing verbatim. */
const DETAILED_ERROR_CODES = new Set([
  "pushRejected",
  "pullRequestCreateFailed",
  "pullRequestExists",
  "commitFailed",
]);

/**
 * The remote's or the forge CLI's own last word (the sidecar appends it after
 * `: `), or `null` for errors the localized label already explains.
 */
export function worktreeErrorDetail(
  code: string | undefined,
  message: string | undefined,
): string | null {
  if (code == null || message == null || !DETAILED_ERROR_CODES.has(code)) {
    return null;
  }
  const separator = message.indexOf(": ");
  if (separator < 0) {
    return null;
  }
  const detail = message.slice(separator + 2).trim();
  return detail === "" ? null : detail;
}

/** Methods whose sidecar handler runs one Git command over many paths. */
const BULK_WRITE_METHODS = new Set<string>([
  "worktreeDiscardAll",
  "worktreeStageAll",
  "worktreeUnstageAll",
]);

/**
 * Error codes a bulk write can only produce before it touched the
 * repository, so the rendered diff is still current after them. Every other
 * failure of a bulk write may have changed some paths before Git gave up
 * on another (`git restore` and `git add -u` exit non-zero as a whole).
 *
 * - `notAllowed`: the token, session, source, or repository was refused
 *   (`worktree.rs` `authorize`), or the commit asked to record an unstaged
 *   view without staging first.
 * - `invalidMessage`: the commit message failed validation, which runs
 *   before `git add -u`.
 * - `invalidRequest`, `requestTooLarge`, `requestTimeout`,
 *   `unsupportedVersion`, `hostUnavailable`: the frame never reached a
 *   handler (`server.rs`).
 * - `closed`, `connectFailed`, `requestFailed`: the transport never
 *   delivered the request or is gone, so a reload could not run either
 *   (`transport.ts`).
 */
const PRE_WRITE_ERROR_CODES = new Set<string>([
  "notAllowed",
  "invalidMessage",
  "invalidRequest",
  "requestTooLarge",
  "requestTimeout",
  "unsupportedVersion",
  "hostUnavailable",
  "closed",
  "connectFailed",
  "requestFailed",
]);

/**
 * Whether `command` writes many paths in one Git command: the session-wide
 * actions, and a commit that stages every tracked change first.
 */
export function isBulkWrite(command: DiffCommand | undefined): boolean {
  if (command == null) {
    return false;
  }
  if (BULK_WRITE_METHODS.has(command.method)) {
    return true;
  }
  return command.method === "worktreeCommit" && command.params.stageAll === true;
}

/**
 * Whether a failed write left the on-disk state ahead of the rendered diff.
 * For any write, a stale or conflicting hunk means the diff changed under the
 * page, and a partial revert changed the index without the working tree. A
 * bulk write (see {@link isBulkWrite}) reloads after every failure past the
 * pre-write rejections in {@link PRE_WRITE_ERROR_CODES}: Git may have changed
 * some of its paths before exiting non-zero for another.
 */
export function worktreeErrorReloads(
  code: string | undefined,
  command?: DiffCommand,
): boolean {
  if (code === "staleHunk" || code === "conflict" || code === "partialRevert") {
    return true;
  }
  return isBulkWrite(command) && !PRE_WRITE_ERROR_CODES.has(code ?? "");
}

// MARK: Repository header and forge availability

/**
 * `~`-abbreviates the current user's home directory on macOS (`/Users/<name>`)
 * and Linux (`/home/<name>`). The page never learns `$HOME`; the prefix shape
 * is enough, and any other path is shown as is.
 */
export function abbreviateHomePath(path: string): string {
  const match = /^(\/Users\/[^/]+|\/home\/[^/]+)(?=\/|$)/.exec(path);
  if (match == null) {
    return path;
  }
  return `~${path.slice(match[1].length)}`;
}

export type RepositoryHeaderModel = {
  repoLabel: string;
  branch: string | null;
  detached: boolean;
  upstream: string | null;
  ahead: number;
  behind: number;
  fileCount: number;
  additions: number;
  deletions: number;
};

/**
 * Header line for a working-tree view: the `~`-abbreviated repository, the
 * branch and upstream position from the last status, and the streamed
 * diff totals (zero while the stream is still starting).
 */
export function repositoryHeaderModel(
  source: WritableDiffSource,
  status: RepositoryStatus | null,
  stats: DiffStats | null | undefined,
): RepositoryHeaderModel {
  return {
    repoLabel: abbreviateHomePath(source.repoRoot),
    branch: status?.branch ?? null,
    detached: status?.detached ?? false,
    upstream: status?.upstream ?? null,
    ahead: status?.ahead ?? 0,
    behind: status?.behind ?? 0,
    fileCount: stats?.fileCount ?? 0,
    additions: stats?.addedLines ?? 0,
    deletions: stats?.deletedLines ?? 0,
  };
}

export type ForgeActionState =
  | "enabled"
  | "unknown"
  | "detached"
  | "noRemote"
  | "noForge"
  | "cliMissing"
  | "notAuthenticated";

export type ForgeActionAvailability = {
  push: ForgeActionState;
  createPullRequest: ForgeActionState;
};

/**
 * What the split button may offer. Push needs a branch and a remote; a pull
 * request additionally needs a known forge, its CLI on the fixed candidate
 * paths, and a signed-in account. Before the first status arrives both are
 * `unknown` (rendered disabled, without a reason).
 */
export function forgeActionAvailability(
  status: RepositoryStatus | null,
): ForgeActionAvailability {
  if (status == null) {
    return { push: "unknown", createPullRequest: "unknown" };
  }
  if (status.detached) {
    return { push: "detached", createPullRequest: "detached" };
  }
  const push: ForgeActionState =
    status.hostKind === "none" ? "noRemote" : "enabled";
  let createPullRequest: ForgeActionState;
  if (status.hostKind === "none") {
    createPullRequest = "noRemote";
  } else if (status.hostKind === "other") {
    createPullRequest = "noForge";
  } else if (!status.forgeCli.available) {
    createPullRequest = "cliMissing";
  } else if (!status.forgeCli.authenticated) {
    createPullRequest = "notAuthenticated";
  } else {
    createPullRequest = "enabled";
  }
  return { push, createPullRequest };
}

/** The reason a disabled forge action shows as its hint, if any. */
export function forgeActionHintKey(
  state: ForgeActionState,
): DiffViewerLabelKey | null {
  switch (state) {
    case "detached":
      return "detachedHead";
    case "noRemote":
      return "noRemote";
    case "noForge":
      return "forgeUnavailable";
    case "cliMissing":
      return "forgeCliMissing";
    case "notAuthenticated":
      return "forgeNotAuthenticated";
    default:
      return null;
  }
}

/** GitLab calls them merge requests; everything else says pull request. */
export function pullRequestLabelKeys(
  hostKind: RepositoryHostKind | null | undefined,
): {
  create: DiffViewerLabelKey;
  dialog: DiffViewerLabelKey;
  submit: DiffViewerLabelKey;
  open: DiffViewerLabelKey;
} {
  if (hostKind === "gitlab") {
    return {
      create: "createMergeRequest",
      dialog: "createMergeRequestDialog",
      submit: "createMergeRequestSubmit",
      open: "openMergeRequest",
    };
  }
  return {
    create: "createPullRequest",
    dialog: "createPullRequestDialog",
    submit: "createPullRequestSubmit",
    open: "openPullRequest",
  };
}

export function pullRequestStateLabelKey(
  request: Pick<PullRequestSummary, "state" | "isDraft">,
): DiffViewerLabelKey {
  if (request.state === "merged") {
    return "prStateMerged";
  }
  if (request.state === "closed") {
    return "prStateClosed";
  }
  return request.isDraft ? "prStateDraft" : "prStateOpen";
}

export function reviewDecisionLabelKey(
  decision: string | null | undefined,
): DiffViewerLabelKey | null {
  switch (decision) {
    case "approved":
      return "reviewApproved";
    case "changes_requested":
      return "reviewChangesRequested";
    case "review_required":
      return "reviewRequired";
    default:
      return null;
  }
}

/** Only `http(s)` links leave the viewer; anything else is not rendered as a link. */
export function externalPullRequestURL(url: string | undefined): string | null {
  if (url == null) {
    return null;
  }
  try {
    const parsed = new URL(url);
    return parsed.protocol === "https:" || parsed.protocol === "http:"
      ? parsed.href
      : null;
  } catch {
    return null;
  }
}
