const DEFAULT_DIFF_VIEWER_LABELS = {
  additions: "Additions",
  aheadBy: "{count} ahead",
  authRequired:
    "Git could not authenticate with the remote. Sign in with your credential helper or SSH agent, then try again.",
  bars: "Bars",
  behindBy: "{count} behind",
  binaryFile: "Binary file",
  branchBase: "Branch base",
  branchPickerCurrent: "current",
  branchPickerBasePrefix: "Base:",
  branchPickerComparing: "Comparing {head} against {base}",
  branchPickerFilterPlaceholder: "Filter branches",
  branchPickerGenerateFailed:
    "Could not generate the diff. Choose a branch to retry.",
  branchPickerGenerating: "Generating diff against {ref}...",
  branchPickerGroupBranches: "Branches",
  branchPickerGroupRecent: "Recent",
  branchPickerGroupRemotes: "Remotes",
  branchPickerGroupSuggested: "Suggested",
  branchPickerGroupWorktrees: "Worktrees",
  branchPickerLoadFailed: "Could not load branches.",
  branchPickerMore: "{count} more, type to filter",
  branchPickerLoading: "Loading branches...",
  branchPickerNoMatches: "No matching branches",
  branchPickerOpen: "Change diff base",
  branchPickerUseRaw: 'Use "{ref}" (raw)',
  cancel: "Cancel",
  changedFiles: "Changed files",
  changedSinceViewed: "Changed since viewed",
  clearFileFilter: "Clear filter",
  changedFilesCount: "{count} files",
  checksFailed: "{count} failed",
  checksPassed: "{passed}/{total} checks passed",
  checksPending: "{count} pending",
  classic: "Classic",
  collapseAllDiffs: "Collapse all diffs",
  collapseFile: "Collapse file",
  collapseUnchangedContext: "Collapse unchanged context",
  commit: "Commit",
  commitActions: "More commit actions",
  commitChanges: "Commit changes",
  commitFailed: "Could not create the commit.",
  commitMessageInvalid: "Enter a commit message of at most 64 KiB.",
  commitMessagePlaceholder: "Commit message",
  commitSubmit: "Commit",
  committed: "Committed {commit}",
  confirmDiscardAll: "Discard all",
  confirmRevert: "Revert",
  copiedPath: "Copied path",
  copyPath: "Copy path",
  copyPathFailed: "Could not copy path.",
  createMergeRequest: "Create MR",
  createMergeRequestDialog: "Create merge request",
  createMergeRequestSubmit: "Create merge request",
  createPullRequest: "Create PR",
  createPullRequestDialog: "Create pull request",
  createPullRequestSubmit: "Create pull request",
  detachedHead: "HEAD is detached. Check out a branch first.",
  detachedHeadShort: "detached",
  discardAll: "Discard all changes…",
  discardAllPrompt: "Discard every change in this view? This cannot be undone.",
  forgeCliMissing:
    "Install the GitHub CLI (gh) or GitLab CLI (glab) to use this action.",
  forgeNotAuthenticated:
    "Sign in with gh auth login or glab auth login, then try again.",
  forgeUnavailable: "Not available for this remote.",
  hunkStale: "This hunk changed on disk. The diff was reloaded.",
  moreActions: "More actions",
  noRemote: "The repository has no remote.",
  noUpstreamShort: "no upstream",
  nothingToCommit: "Nothing to commit.",
  openInCmux: "Open in cmux",
  openInCmuxFailed: "Could not open the file in cmux.",
  openMergeRequest: "Open merge request",
  openPullRequest: "Open pull request",
  prStateClosed: "Closed",
  prStateDraft: "Draft",
  prStateMerged: "Merged",
  prStateOpen: "Open",
  pullRequestBase: "into {base}",
  pullRequestBaseInvalid: "Enter a valid base branch name.",
  pullRequestBasePlaceholder: "Base branch (default)",
  pullRequestBodyInvalid: "The description is too long (64 KiB max).",
  pullRequestBodyPlaceholder: "Description (optional)",
  pullRequestCreateFailed: "Could not create the pull request.",
  pullRequestCreated: "Created #{number}",
  pullRequestDraft: "Create as draft",
  pullRequestExists: "A pull request already exists for this branch.",
  pullRequestTitleInvalid: "Enter a title of at most 256 bytes.",
  pullRequestTitlePlaceholder: "Title",
  push: "Push",
  pushNoUpstream: "The branch has no upstream yet.",
  pushRejected: "The remote rejected the push.",
  pushed: "Pushed {branch} to {remote}",
  pushedUpstreamCreated: "Pushed {branch} to {remote} and set the upstream",
  reviewApproved: "Approved",
  reviewChangesRequested: "Changes requested",
  reviewRequired: "Review required",
  revertFile: "Revert changes",
  revertHunk: "Revert hunk",
  revertPrompt: "Discard these changes?",
  stageAll: "Stage all",
  stageAllAndCommit: "Stage all and commit",
  stageFile: "Stage file",
  unstageAll: "Unstage all",
  unstageFile: "Unstage file",
  worktreeConflict:
    "The change could not be applied cleanly. The diff was reloaded.",
  worktreeNotAllowed: "Working-tree changes are not available for this diff.",
  worktreePartialRevert:
    "The change was unstaged but is still in the working tree. The diff was reloaded.",
  worktreeWriteFailed: "Could not update the working tree.",
  copyFailedGitApplyCommand: "Could not copy git apply command.",
  copiedGitApplyCommand: "Copied git apply command",
  copyGitApplyCommand: "Copy git apply command",
  deletions: "Deletions",
  diffStats: "Diff stats",
  diffTarget: "Diff target",
  diffViewer: "Diff viewer",
  disableWordDiffs: "Disable word diffs",
  disableWordWrap: "Disable word wrap",
  enableWordDiffs: "Enable word diffs",
  enableWordWrap: "Enable word wrap",
  expandAllDiffs: "Expand all diffs",
  expandFile: "Expand file",
  expandUnchangedContext: "Expand unchanged context",
  files: "Files",
  filesViewedProgress: "{viewed} of {total} files viewed",
  filterAddedFiles: "Added",
  filterDeletedFiles: "Deleted",
  filterFiles: "Filter files",
  filterModifiedFiles: "Modified",
  filterRenamedFiles: "Renamed",
  findClose: "Close find",
  findInDiff: "Find in diff",
  findNextMatch: "Next match",
  findPreviousMatch: "Previous match",
  generatedFile: "Generated file",
  hideBackgrounds: "Hide backgrounds",
  hideFiles: "Hide files",
  hideFileSearch: "Hide file search",
  hideLineNumbers: "Hide line numbers",
  hideViewedFiles: "Hide viewed files",
  indicatorStyle: "Indicator style",
  jumpToFile: "Jump to file",
  largeDiff: "Large diff",
  loadDiff: "Load diff",
  loadingDiff: "Loading diff...",
  loadingRenderer: "Loading renderer...",
  markNotViewed: "Mark as not viewed",
  markViewed: "Mark as viewed",
  modeChange: "Mode {old} → {new}",
  noFileDiffs: "No file diffs found in patch input.",
  noFilesMatchFilter: "No files match the filter.",
  none: "None",
  openSourceURL: "Open source URL",
  options: "Options",
  parsingDiff: "Parsing diff...",
  refresh: "Refresh",
  renderFailed:
    "Could not render this diff. Check the patch input and try again.",
  renderingDiff: "Rendering diff...",
  repoPath: "Repository path",
  showBackgrounds: "Show backgrounds",
  showFiles: "Show files",
  showFileSearch: "Show file search",
  showLineNumbers: "Show line numbers",
  showViewedFiles: "Show viewed files",
  switchToSplitDiff: "Switch to split diff",
  switchToUnifiedDiff: "Switch to unified diff",
  untitled: "Untitled",
  viewed: "Viewed",
} as const;

export type DiffViewerLabelKey = keyof typeof DEFAULT_DIFF_VIEWER_LABELS;
export type DiffViewerLabelResolver = (key: DiffViewerLabelKey) => string;

/** Every label key the viewer can ask for, for parity checks against the host's map. */
export const DIFF_VIEWER_LABEL_KEYS = Object.keys(
  DEFAULT_DIFF_VIEWER_LABELS,
) as DiffViewerLabelKey[];

type LabelResolverOptions = {
  assertMissing?: boolean;
};

export function shouldAssertMissingLabels(): boolean {
  return Boolean(import.meta.env?.DEV);
}

export function createDiffViewerLabelResolver(
  labels: Record<string, string> | undefined,
  options: LabelResolverOptions = {},
): DiffViewerLabelResolver {
  const missingKeys = new Set<DiffViewerLabelKey>();
  return (key) => {
    const localizedValue = labels?.[key];
    if (typeof localizedValue === "string" && localizedValue.trim() !== "") {
      return localizedValue;
    }

    if (options.assertMissing && !missingKeys.has(key)) {
      missingKeys.add(key);
      throw new Error(`Missing cmux diff viewer label: ${key}`);
    }

    return DEFAULT_DIFF_VIEWER_LABELS[key];
  };
}

/** Substitutes `{name}` placeholders in a resolved label. */
export function formatLabel(
  template: string,
  values: Record<string, string | number>,
): string {
  return template.replace(/\{(\w+)\}/g, (match, name: string) =>
    Object.hasOwn(values, name) ? String(values[name]) : match,
  );
}
