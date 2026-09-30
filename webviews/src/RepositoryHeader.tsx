import { useCallback, useEffect, useState } from "react";
import type {
  PullRequestSummary,
  RepositoryStatus,
} from "./diff/generated/protocol";
import { Icon } from "./icons";
import {
  formatCountLabel,
  formatLabel,
  type DiffViewerLabelResolver,
} from "./labels";
import { MenuButton } from "./ViewOptionsMenu";
import {
  CommitPopover,
  InlineConfirmation,
  PullRequestCard,
  PullRequestPopover,
  WorktreeNoticeView,
  useDismissOnOutsideInteraction,
  type WorktreeNotice,
} from "./WorktreeActions";
import {
  forgeActionAvailability,
  forgeActionHintKey,
  pullRequestLabelKeys,
  writeActionId,
  writeVerbsForSource,
  type CommitAvailability,
  type PullRequestDraft,
  type RepositoryHeaderModel,
  type WritableDiffSource,
  type WriteVerb,
  type WriteVerbDescriptor,
} from "./worktree-actions";

/**
 * Repository header for working-tree views: the source/repo/base pickers
 * (passed in by the App, which renders them from exactly one host), then
 * `<branch> · N files +A -D · position`, and on the right the primary split
 * button (Commit, with Push and Create PR/MR in its menu), the files-list
 * toggle, and the view's one "..." menu: the batch actions first (Stage all
 * and Discard all changes… in the Unstaged view, Unstage all alone in the
 * Staged view, which never touches the working tree; while files are
 * checked, Stage N files / Discard N files… or Unstage N files, and Clear
 * selection; the "..." button wears the count), then every view option the
 * toolbar menu offers (shared
 * `ViewOptionsMenuItems`), then copy and refresh. This header
 * is the view's only top row; the toolbar does not render alongside it. When
 * the payload offers no repo select, the plain abbreviated repo label
 * precedes the branch so the view still names its repository. Menus and
 * popovers are clusters of native buttons toggled with
 * `aria-expanded`/`aria-controls` and dismissed on outside click or Escape;
 * nothing here reimplements a composite ARIA widget.
 */

export type CommitControl = {
  availability: Exclude<CommitAvailability, "hidden">;
  open: boolean;
  onClose: () => void;
  onCommit: (message: string, stageAll: boolean) => void;
  onToggle: () => void;
};

export type PullRequestControl = {
  open: boolean;
  onClose: () => void;
  onCreate: (draft: PullRequestDraft) => void;
  onToggle: () => void;
  /** The branch's request, from the status or the one just created. */
  current: PullRequestSummary | null;
};

/** The checked files of the current view and the actions over them. */
export type SelectionControl = {
  /**
   * The checked paths in diff order; empty shows the "all" actions. A
   * selection action posts the list it was invoked with, never the live one.
   */
  paths: readonly string[];
  onAction: (verb: WriteVerb, paths: readonly string[]) => void;
  onClear: () => void;
};

/**
 * A confirming verb with the scope captured when its menu item was clicked:
 * the checked paths then (empty: the whole view). The prompt, the confirm
 * label and the request all read this capture, never the live selection,
 * so a selection that empties under the popover (Space on a tree row fires
 * no mousedown; a reload keeps the set but not its items) can never turn
 * "Discard selected" into "Discard all".
 */
type PendingConfirmation = {
  descriptor: WriteVerbDescriptor;
  paths: readonly string[];
};

/** The open menu, or the confirmation popover that replaced the menu. */
type OpenMenu = "commit" | "overflow" | { confirm: PendingConfirmation } | null;

function samePaths(a: readonly string[], b: readonly string[]): boolean {
  return a.length === b.length && a.every((path, index) => path === b[index]);
}

export function RepositoryHeader({
  commit,
  diffGeneration,
  files,
  label,
  model,
  notice,
  onBulkAction,
  onCopyGitApply,
  onNoticeExpire,
  onPush,
  onRefresh,
  pending,
  pullRequest,
  selection,
  showRepoLabel,
  source,
  sourceControls,
  status,
  viewOptions,
}: {
  commit: CommitControl;
  /**
   * Counts the diff resets (a reload or a view change); every open menu
   * closes on one.
   */
  diffGeneration: number;
  /** The files-list toggle: the file column is how this view navigates files. */
  files: { visible: boolean; onToggle: () => void };
  label: DiffViewerLabelResolver;
  model: RepositoryHeaderModel;
  notice: WorktreeNotice | null;
  onBulkAction: (verb: WriteVerb) => void;
  onCopyGitApply: () => void;
  onNoticeExpire: (token: number) => void;
  onPush: () => void;
  onRefresh: () => void;
  pending: boolean;
  pullRequest: PullRequestControl;
  selection: SelectionControl;
  /** True when no repo select renders, so the abbreviated repo path is shown as text. */
  showRepoLabel: boolean;
  source: WritableDiffSource;
  /** The source/repo/base pickers, hosted here instead of in the toolbar. */
  sourceControls: React.ReactNode;
  status: RepositoryStatus | null;
  /** The shared view options (`ViewOptionsMenuItems`) for the "..." menu. */
  viewOptions: React.ReactNode;
}) {
  const [openMenu, setOpenMenu] = useState<OpenMenu>(null);
  const closeMenus = useCallback(() => setOpenMenu(null), []);
  useDismissOnOutsideInteraction(openMenu != null, closeMenus, "#repo-header");
  const confirming =
    openMenu != null && typeof openMenu === "object"
      ? openMenu.confirm
      : null;
  // A reload or a view change resets the diff: whatever a menu or the
  // confirmation showed belongs to the view before it.
  useEffect(() => {
    closeMenus();
  }, [closeMenus, diffGeneration]);
  // The confirmation asked about one selection; when the live selection
  // stops matching the captured one (a row toggled, the set cleared or
  // pruned), the question no longer applies and the popover closes.
  const capturedPaths = confirming?.paths ?? null;
  const livePaths = selection.paths;
  useEffect(() => {
    if (capturedPaths != null && !samePaths(capturedPaths, livePaths)) {
      closeMenus();
    }
  }, [capturedPaths, closeMenus, livePaths]);
  useDismissOnOutsideInteraction(
    commit.open,
    commit.onClose,
    "#commit-popover, #commit-button",
  );
  useDismissOnOutsideInteraction(
    pullRequest.open,
    pullRequest.onClose,
    "#pull-request-popover, #commit-menu",
  );
  const availability = forgeActionAvailability(status);
  const hostKind = status?.hostKind ?? null;
  const requestKeys = pullRequestLabelKeys(hostKind);
  const toggleMenu = (menu: "commit" | "overflow") => {
    setOpenMenu((current) => (current === menu ? null : menu));
  };
  const runFromMenu = (action: () => void) => {
    closeMenus();
    action();
  };
  const pushHint = forgeActionHintKey(availability.push);
  const requestHint = forgeActionHintKey(availability.createPullRequest);
  const selectedCount = selection.paths.length;
  const selecting = selectedCount > 0;
  // The batch actions: the view's verbs over the whole view while nothing is
  // checked, over the checked files otherwise. A verb that confirms asks
  // first, in a popover under the header, about the selection as it was
  // when the item was clicked.
  const scope = selecting ? "selected" : "all";
  const verbs = writeVerbsForSource(source);
  const verbLabel = (descriptor: WriteVerbDescriptor) =>
    selecting
      ? formatCountLabel(label, descriptor.label.selected, selectedCount)
      : label(descriptor.label.all);
  const runVerb = (
    descriptor: WriteVerbDescriptor,
    paths: readonly string[],
  ) =>
    paths.length > 0
      ? selection.onAction(descriptor.verb, paths)
      : onBulkAction(descriptor.verb);
  // Confirm posts the captured scope, and only while the live selection
  // still matches it: the effect above closes a stale popover, and this
  // guards the same frame.
  const runConfirmed = ({ descriptor, paths }: PendingConfirmation) => {
    if (samePaths(paths, selection.paths)) {
      runVerb(descriptor, paths);
    }
  };
  const confirmScope = confirming?.paths.length ? "selected" : "all";
  const confirmation = confirming?.descriptor.confirm?.[confirmScope];
  const moreActions = selecting
    ? formatLabel(label("moreActionsWithSelection"), { count: selectedCount })
    : label("moreActions");
  return (
    <header id="repo-header" data-pending={pending ? "true" : "false"}>
      <div className="repo-header-summary">
        {sourceControls}
        <span className="repo-header-status">
          {showRepoLabel || model.branch ? (
            <span className="repo-header-title" title={source.repoRoot}>
              {showRepoLabel ? (
                <span className="repo-header-repo">{model.repoLabel}</span>
              ) : null}
              {showRepoLabel && model.branch ? (
                <span className="repo-header-separator">:</span>
              ) : null}
              {model.branch ? (
                <span
                  className="repo-header-branch"
                  data-detached={model.detached ? "true" : "false"}
                >
                  <Icon name="branch" />
                  {model.branch}
                </span>
              ) : null}
            </span>
          ) : null}
          {model.branch ? <HeaderDot /> : null}
          <span className="repo-header-stats" aria-label={label("diffStats")}>
            <span className="repo-header-files">
              {formatCountLabel(label, "changedFilesCount", model.fileCount)}
            </span>
            <span className="repo-header-additions">+{model.additions}</span>
            <span className="repo-header-deletions">-{model.deletions}</span>
            {status != null && !model.detached ? (
              <>
                <HeaderDot />
                <span className="repo-header-position">
                  {model.upstream == null
                    ? label("noUpstreamShort")
                    : [
                        model.ahead > 0
                          ? formatLabel(label("aheadBy"), {
                              count: model.ahead,
                            })
                          : null,
                        model.behind > 0
                          ? formatLabel(label("behindBy"), {
                              count: model.behind,
                            })
                          : null,
                      ]
                        .filter(Boolean)
                        .join(" · ")}
                </span>
              </>
            ) : null}
            {model.detached ? (
              <>
                <HeaderDot />
                <span className="repo-header-position">
                  {label("detachedHeadShort")}
                </span>
              </>
            ) : null}
          </span>
        </span>
      </div>
      <div className="repo-header-actions">
        <span
          className="split-button"
          data-open={openMenu === "commit" ? "true" : "false"}
        >
          <button
            id="commit-button"
            type="button"
            className="split-button-primary"
            disabled={pending}
            title={label("commitChanges")}
            aria-expanded={commit.open}
            aria-controls="commit-popover"
            data-availability={commit.availability}
            onClick={() => {
              closeMenus();
              commit.onToggle();
            }}
          >
            <Icon name="commit" />
            <span className="commit-button-label">{label("commitSubmit")}</span>
          </button>
          <button
            id="commit-menu-button"
            type="button"
            className="split-button-menu"
            title={label("commitActions")}
            aria-label={label("commitActions")}
            aria-expanded={openMenu === "commit"}
            aria-controls="commit-menu"
            onClick={() => toggleMenu("commit")}
          >
            <Icon name="chevronDown" />
          </button>
        </span>
        <button
          id="files-toggle"
          className="toolbar-icon"
          type="button"
          title={files.visible ? label("hideFiles") : label("showFiles")}
          aria-label={files.visible ? label("hideFiles") : label("showFiles")}
          aria-pressed={files.visible}
          onClick={files.onToggle}
        >
          <Icon name="files" />
        </button>
        <button
          id="repo-overflow-button"
          type="button"
          className="toolbar-icon"
          title={moreActions}
          aria-label={moreActions}
          aria-expanded={openMenu === "overflow"}
          aria-controls="repo-overflow-menu"
          data-selection-count={selecting ? selectedCount : undefined}
          onClick={() => toggleMenu("overflow")}
        >
          <Icon name="dots" />
        </button>
      </div>
      {confirming && confirmation ? (
        <div id="discard-popover" className="repo-menu repo-menu-confirm">
          <InlineConfirmation
            cancelLabel={label("cancel")}
            confirmLabel={label(confirmation.button)}
            onCancel={closeMenus}
            onConfirm={() => runFromMenu(() => runConfirmed(confirming))}
            pending={pending}
            prompt={label(confirmation.prompt)}
          />
        </div>
      ) : null}
      {openMenu === "commit" ? (
        <div id="commit-menu" className="repo-menu">
          {/* The split button's primary action is Commit; the menu holds the rest. */}
          <MenuButton
            action="push"
            icon="push"
            label={label("push")}
            disabled={pending || availability.push !== "enabled"}
            title={pushHint ? label(pushHint) : undefined}
            onClick={() => runFromMenu(onPush)}
          />
          <MenuButton
            action="createPullRequest"
            icon="pullRequest"
            label={label(requestKeys.create)}
            disabled={pending || availability.createPullRequest !== "enabled"}
            title={requestHint ? label(requestHint) : undefined}
            onClick={() => runFromMenu(pullRequest.onToggle)}
          />
        </div>
      ) : null}
      {openMenu === "overflow" ? (
        <div id="repo-overflow-menu" className="repo-menu">
          {/* The batch actions first (a confirming verb swaps this menu for
              its confirmation popover), then the view options, which stay
              open on toggle like the toolbar menu does, then copy and refresh. */}
          {verbs.map((descriptor) => (
            <MenuButton
              key={descriptor.verb}
              action={writeActionId(descriptor.verb, scope)}
              danger={descriptor.confirm != null}
              disabled={pending}
              icon={descriptor.icon}
              label={verbLabel(descriptor)}
              onClick={() =>
                descriptor.confirm
                  ? setOpenMenu({
                      confirm: { descriptor, paths: selection.paths },
                    })
                  : runFromMenu(() => runVerb(descriptor, selection.paths))
              }
            />
          ))}
          {selecting ? (
            <MenuButton
              action="clearSelection"
              icon="close"
              label={label("clearSelection")}
              onClick={() => runFromMenu(selection.onClear)}
            />
          ) : null}
          <div className="menu-separator" />
          {viewOptions}
          <div className="menu-separator" />
          <MenuButton
            icon="clipboard"
            label={label("copyGitApplyCommand")}
            onClick={() => runFromMenu(onCopyGitApply)}
          />
          <MenuButton
            action="refresh"
            icon="refresh"
            label={label("refresh")}
            onClick={() => runFromMenu(onRefresh)}
          />
        </div>
      ) : null}
      {commit.open ? (
        <CommitPopover
          availability={commit.availability}
          label={label}
          onCancel={commit.onClose}
          onCommit={commit.onCommit}
          pending={pending}
        />
      ) : null}
      {pullRequest.open ? (
        <PullRequestPopover
          hostKind={hostKind}
          label={label}
          onCancel={pullRequest.onClose}
          onCreate={pullRequest.onCreate}
          pending={pending}
        />
      ) : null}
      <WorktreeNoticeView notice={notice} onExpire={onNoticeExpire} />
      {pullRequest.current ? (
        <PullRequestCard
          hostKind={hostKind}
          label={label}
          request={pullRequest.current}
        />
      ) : null}
    </header>
  );
}

/** Visual separator between header segments; screen readers skip it. */
function HeaderDot() {
  return (
    <span className="repo-header-dot" aria-hidden="true">
      ·
    </span>
  );
}
