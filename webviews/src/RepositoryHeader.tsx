import { useCallback, useState } from "react";
import type {
  PullRequestSummary,
  RepositoryStatus,
} from "./diff/generated/protocol";
import { Icon, type IconName } from "./icons";
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
 * `<branch> · N files +A -D · position`, and on the right the batch actions
 * (Stage all / Unstage all and Discard all…, or, while files are checked,
 * Stage N files / Discard N files… and Clear selection), the primary split
 * button (Commit, with Push and Create PR/MR in its menu), the files-list
 * toggle, and the view's one "..." menu: every view option the toolbar menu
 * offers (shared `ViewOptionsMenuItems`), then copy and refresh. This header
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

const BULK_ACTION_ICON: Record<BulkWriteAction, IconName> = {
  discardAll: "trash",
  stageAll: "stage",
  unstageAll: "unstage",
};

const SELECTION_ACTION_ICON: Record<SelectionWriteAction, IconName> = {
  discardFiles: "trash",
  stageFiles: "stage",
  unstageFiles: "unstage",
};

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
        {/* The batch actions: whole view while nothing is checked, the
            checked files otherwise. Discard asks first, in a popover under
            the header. Icon-only at narrow widths (container query). */}
        <span
          className="repo-header-bulk"
          data-selecting={selecting ? "true" : "false"}
        >
          {selecting
            ? selectionActionsForSource(source).map((action) => {
                const text =
                  action === "discardFiles"
                    ? formatCountLabel(
                        label,
                        "discardSelected",
                        selection.count,
                      )
                    : formatCountLabel(
                        label,
                        action === "stageFiles"
                          ? "stageSelected"
                          : "unstageSelected",
                        selection.count,
                      );
                const discard = action === "discardFiles";
                return (
                  <HeaderActionButton
                    key={action}
                    action={action}
                    danger={discard}
                    disabled={pending}
                    expanded={discard ? openMenu === "discard" : undefined}
                    icon={SELECTION_ACTION_ICON[action]}
                    label={text}
                    onClick={() =>
                      discard
                        ? toggleMenu("discard")
                        : runFromMenu(() => selection.onAction(action))
                    }
                  />
                );
              })
            : bulkActionsForSource(source).map((action) => {
                const discard = action === "discardAll";
                return (
                  <HeaderActionButton
                    key={action}
                    action={action}
                    danger={discard}
                    disabled={pending}
                    expanded={discard ? openMenu === "discard" : undefined}
                    icon={BULK_ACTION_ICON[action]}
                    label={discard ? label("discardAllShort") : label(action)}
                    title={discard ? label("discardAll") : undefined}
                    onClick={() =>
                      discard
                        ? toggleMenu("discard")
                        : runFromMenu(() => onBulkAction(action))
                    }
                  />
                );
              })}
          {selecting ? (
            <HeaderActionButton
              action="clearSelection"
              icon="close"
              label={label("clearSelection")}
              onClick={() => runFromMenu(selection.onClear)}
            />
          ) : null}
        </span>
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
          title={label("moreActions")}
          aria-label={label("moreActions")}
          aria-expanded={openMenu === "overflow"}
          aria-controls="repo-overflow-menu"
          onClick={() => toggleMenu("overflow")}
        >
          <Icon name="dots" />
        </button>
      </div>
      {openMenu === "discard" ? (
        <div id="discard-popover" className="repo-menu repo-menu-confirm">
          {selecting ? (
            <InlineConfirmation
              cancelLabel={label("cancel")}
              confirmLabel={label("confirmDiscardSelected")}
              onCancel={closeMenus}
              onConfirm={() =>
                runFromMenu(() => selection.onAction("discardFiles"))
              }
              pending={pending}
              prompt={label("discardSelectedPrompt")}
            />
          ) : (
            <InlineConfirmation
              cancelLabel={label("cancel")}
              confirmLabel={label("confirmDiscardAll")}
              onCancel={closeMenus}
              onConfirm={() => runFromMenu(() => onBulkAction("discardAll"))}
              pending={pending}
              prompt={label("discardAllPrompt")}
            />
          )}
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
          {/* View options stay open on toggle, like the toolbar menu does. The
              batch actions live in the header itself, not here. */}
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

/**
 * One batch action of the header: icon plus text, the text hidden by the
 * header's container query at narrow widths, so `title` (the text unless
 * given) keeps naming the action.
 */
function HeaderActionButton({
  action,
  danger,
  disabled,
  expanded,
  icon,
  label,
  onClick,
  title,
}: {
  action: string;
  danger?: boolean;
  disabled?: boolean;
  /** Set for the discard buttons, which open the confirmation popover. */
  expanded?: boolean;
  icon: IconName;
  label: string;
  onClick: () => void;
  title?: string;
}) {
  return (
    <button
      type="button"
      className="header-action"
      data-action={action}
      data-danger={danger ? "true" : undefined}
      disabled={disabled}
      title={title ?? label}
      aria-label={title ?? label}
      aria-expanded={expanded}
      aria-controls={expanded == null ? undefined : "discard-popover"}
      onClick={onClick}
    >
      <Icon name={icon} />
      <span className="header-action-label">{label}</span>
    </button>
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
