import { useCallback, useState } from "react";
import type {
  PullRequestSummary,
  RepositoryStatus,
} from "./diff/generated/protocol";
import { Icon, type IconName } from "./icons";
import { formatLabel, type DiffViewerLabelResolver } from "./labels";
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
  bulkStageActionForSource,
  forgeActionAvailability,
  forgeActionHintKey,
  pullRequestLabelKeys,
  type BulkWriteAction,
  type CommitAvailability,
  type PullRequestDraft,
  type RepositoryHeaderModel,
  type WritableDiffSource,
} from "./worktree-actions";

/**
 * Repository header for working-tree views: the source/repo/base pickers
 * (passed in by the App, which renders them from exactly one host), then
 * `<branch> · N files +A -D · position`, and the primary split button
 * (Commit, with Push and Create PR/MR in its menu) plus a "..." overflow for
 * whole-session actions. When the payload offers no repo select, the plain
 * abbreviated repo label precedes the branch so the view still names its
 * repository. Menus and popovers are clusters of native buttons toggled with
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

type OpenMenu = "commit" | "overflow" | null;

export function RepositoryHeader({
  commit,
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
  showRepoLabel,
  source,
  sourceControls,
  status,
}: {
  commit: CommitControl;
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
  /** True when no repo select renders, so the abbreviated repo path is shown as text. */
  showRepoLabel: boolean;
  source: WritableDiffSource;
  /** The source/repo/base pickers, hosted here instead of in the toolbar. */
  sourceControls: React.ReactNode;
  status: RepositoryStatus | null;
}) {
  const [openMenu, setOpenMenu] = useState<OpenMenu>(null);
  const [confirmingDiscard, setConfirmingDiscard] = useState(false);
  const closeMenus = useCallback(() => {
    setOpenMenu(null);
    setConfirmingDiscard(false);
  }, []);
  useDismissOnOutsideInteraction(openMenu != null, closeMenus, "#repo-header");
  useDismissOnOutsideInteraction(
    pullRequest.open,
    pullRequest.onClose,
    "#pull-request-popover, #commit-menu",
  );
  const availability = forgeActionAvailability(status);
  const hostKind = status?.hostKind ?? null;
  const requestKeys = pullRequestLabelKeys(hostKind);
  const stageAction = bulkStageActionForSource(source);
  const toggleMenu = (menu: Exclude<OpenMenu, null>) => {
    setConfirmingDiscard(false);
    setOpenMenu((current) => (current === menu ? null : menu));
  };
  const runFromMenu = (action: () => void) => {
    closeMenus();
    action();
  };
  const pushHint = forgeActionHintKey(availability.push);
  const requestHint = forgeActionHintKey(availability.createPullRequest);
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
      {openMenu === "commit" ? (
        <div id="commit-menu" className="repo-menu">
          <HeaderMenuButton
            icon="commit"
            label={label("commitChanges")}
            disabled={pending}
            onClick={() => runFromMenu(commit.onToggle)}
          />
          <HeaderMenuButton
            action="push"
            icon="push"
            label={label("push")}
            disabled={pending || availability.push !== "enabled"}
            title={pushHint ? label(pushHint) : undefined}
            onClick={() => runFromMenu(onPush)}
          />
          <HeaderMenuButton
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
          {confirmingDiscard ? (
            <div className="repo-menu-confirm">
              <InlineConfirmation
                cancelLabel={label("cancel")}
                confirmLabel={label("confirmDiscardAll")}
                onCancel={() => setConfirmingDiscard(false)}
                onConfirm={() => runFromMenu(() => onBulkAction("discardAll"))}
                pending={pending}
                prompt={label("discardAllPrompt")}
              />
            </div>
          ) : (
            <HeaderMenuButton
              action="discardAll"
              danger
              icon="trash"
              label={label("discardAll")}
              disabled={pending}
              onClick={() => setConfirmingDiscard(true)}
            />
          )}
          {stageAction ? (
            <HeaderMenuButton
              action={stageAction}
              icon={stageAction === "stageAll" ? "stage" : "unstage"}
              label={label(stageAction)}
              disabled={pending}
              onClick={() => runFromMenu(() => onBulkAction(stageAction))}
            />
          ) : null}
          <div className="menu-separator" />
          <HeaderMenuButton
            icon="clipboard"
            label={label("copyGitApplyCommand")}
            onClick={() => runFromMenu(onCopyGitApply)}
          />
          <HeaderMenuButton
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

function HeaderMenuButton({
  action,
  danger,
  disabled,
  icon,
  label,
  onClick,
  title,
}: {
  action?: string;
  danger?: boolean;
  disabled?: boolean;
  icon: IconName;
  label: string;
  onClick: () => void;
  title?: string;
}) {
  return (
    <button
      type="button"
      className="menu-item"
      data-action={action}
      data-danger={danger ? "true" : undefined}
      disabled={disabled}
      title={title}
      onClick={onClick}
    >
      <Icon name={icon} />
      <span className="menu-label">{label}</span>
    </button>
  );
}
