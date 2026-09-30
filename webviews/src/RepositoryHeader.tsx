import { useCallback, useState } from "react";
import type {
  PullRequestSummary,
  RepositoryStatus,
} from "./diff/generated/protocol";
import { Icon, type IconName } from "./icons";
import {
  formatCountLabel,
  formatLabel,
  type CountLabelKey,
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
  bulkActionsForSource,
  forgeActionAvailability,
  forgeActionHintKey,
  pullRequestLabelKeys,
  selectionActionsForSource,
  type BulkWriteAction,
  type CommitAvailability,
  type PullRequestDraft,
  type RepositoryHeaderModel,
  type SelectionWriteAction,
  type WritableDiffSource,
} from "./worktree-actions";

/**
 * Repository header for working-tree views: the source/repo/base pickers
 * (passed in by the App, which renders them from exactly one host), then
 * `<branch> · N files +A -D · position`, and on the right the primary split
 * button (Commit, with Push and Create PR/MR in its menu), the files-list
 * toggle, and the view's one "..." menu: the batch actions first (Stage all /
 * Unstage all and Discard all changes…, or, while files are checked, Stage N
 * files / Discard N files… and Clear selection; the "..." button wears the
 * count), then every view option the toolbar menu offers (shared
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
  /** How many of the view's files are checked; zero shows the "all" actions. */
  count: number;
  onAction: (action: SelectionWriteAction) => void;
  onClear: () => void;
};

type OpenMenu = "commit" | "discard" | "overflow" | null;

/** A whole-view action or its selection-scoped counterpart; the keys are disjoint. */
type BatchAction = BulkWriteAction | SelectionWriteAction;

const ACTION_ICON: Record<BatchAction, IconName> = {
  discardAll: "trash",
  discardFiles: "trash",
  stageAll: "stage",
  stageFiles: "stage",
  unstageAll: "unstage",
  unstageFiles: "unstage",
};

/** The `{count}` label of each selection action; `formatCountLabel` picks the singular. */
const SELECTION_LABEL_KEY: Record<SelectionWriteAction, CountLabelKey> = {
  discardFiles: "discardSelected",
  stageFiles: "stageSelected",
  unstageFiles: "unstageSelected",
};

function isSelectionAction(
  action: BatchAction,
): action is SelectionWriteAction {
  return action in SELECTION_LABEL_KEY;
}

/** Discard asks first: its menu item opens the confirmation popover instead of running. */
function isDiscard(action: BatchAction): boolean {
  return action === "discardAll" || action === "discardFiles";
}

export function RepositoryHeader({
  commit,
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
  /** The files-list toggle: the file column is how this view navigates files. */
  files: { visible: boolean; onToggle: () => void };
  label: DiffViewerLabelResolver;
  model: RepositoryHeaderModel;
  notice: WorktreeNotice | null;
  onBulkAction: (action: BulkWriteAction) => void;
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
  const toggleMenu = (menu: Exclude<OpenMenu, null>) => {
    setOpenMenu((current) => (current === menu ? null : menu));
  };
  const runFromMenu = (action: () => void) => {
    closeMenus();
    action();
  };
  const pushHint = forgeActionHintKey(availability.push);
  const requestHint = forgeActionHintKey(availability.createPullRequest);
  const selecting = selection.count > 0;
  // The batch actions: the whole view while nothing is checked, the checked
  // files otherwise. Discard asks first, in a popover under the header.
  const batchActions: BatchAction[] = selecting
    ? selectionActionsForSource(source)
    : bulkActionsForSource(source);
  const batchActionLabel = (action: BatchAction) =>
    isSelectionAction(action)
      ? formatCountLabel(label, SELECTION_LABEL_KEY[action], selection.count)
      : label(action);
  const runBatchAction = (action: BatchAction) =>
    isSelectionAction(action)
      ? selection.onAction(action)
      : onBulkAction(action);
  const moreActions = selecting
    ? formatLabel(label("moreActionsWithSelection"), { count: selection.count })
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
              {formatLabel(label("changedFilesCount"), {
                count: model.fileCount,
              })}
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
          data-selection-count={selecting ? selection.count : undefined}
          onClick={() => toggleMenu("overflow")}
        >
          <Icon name="dots" />
        </button>
      </div>
      {openMenu === "discard" ? (
        <div id="discard-popover" className="repo-menu repo-menu-confirm">
          <InlineConfirmation
            cancelLabel={label("cancel")}
            confirmLabel={label(
              selecting ? "confirmDiscardSelected" : "confirmDiscardAll",
            )}
            onCancel={closeMenus}
            onConfirm={() =>
              runFromMenu(() =>
                runBatchAction(selecting ? "discardFiles" : "discardAll"),
              )
            }
            pending={pending}
            prompt={label(
              selecting ? "discardSelectedPrompt" : "discardAllPrompt",
            )}
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
          {/* The batch actions first (a discard swaps this menu for its
              confirmation popover), then the view options, which stay open
              on toggle like the toolbar menu does, then copy and refresh. */}
          {batchActions.map((action) => (
            <MenuButton
              key={action}
              action={action}
              danger={isDiscard(action)}
              disabled={pending}
              icon={ACTION_ICON[action]}
              label={batchActionLabel(action)}
              onClick={() =>
                isDiscard(action)
                  ? toggleMenu("discard")
                  : runFromMenu(() => runBatchAction(action))
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
