import { useCallback, useEffect, useState } from "react";
import type {
  PullRequestSummary,
  RepositoryHostKind,
} from "./diff/generated/protocol";
import { Icon, type IconName } from "./icons";
import {
  formatLabel,
  type DiffViewerLabelKey,
  type DiffViewerLabelResolver,
} from "./labels";
import {
  externalPullRequestURL,
  pullRequestLabelKeys,
  pullRequestStateLabelKey,
  reviewDecisionLabelKey,
  validateCommitMessage,
  validatePullRequestDraft,
  type CommitAvailability,
  type CommitMessageValidation,
  type FileWriteAction,
  type PullRequestDraft,
  type PullRequestValidation,
} from "./worktree-actions";

/**
 * Header-slot and write-action controls for the diff viewer: the per-file
 * fold chevron, per-file header buttons, the per-hunk action row, the commit
 * and pull request popovers, and the pull request card. Every destructive
 * action asks for an inline confirmation first; nothing here talks to the
 * transport, the App owns the request and the reload.
 */

const FILE_ACTION_ICON: Record<FileWriteAction, IconName> = {
  revertFile: "revert",
  stageFile: "stage",
  unstageFile: "unstage",
};

/**
 * Per-file fold control, slotted at the front of the card header. The fold
 * state is the item's controlled `collapsed` (the App's reducer owns it and
 * CodeView re-renders the card), so this is a plain button reporting the
 * click; the header itself never toggles anything.
 */
export function FileCollapseToggle({
  collapsed,
  label,
  onToggle,
}: {
  collapsed: boolean;
  label: DiffViewerLabelResolver;
  onToggle: () => void;
}) {
  const title = label(collapsed ? "expandFile" : "collapseFile");
  return (
    <button
      type="button"
      className="file-collapse-toggle"
      aria-expanded={!collapsed}
      aria-label={title}
      title={title}
      onClick={onToggle}
    >
      <Icon name="chevronDown" />
    </button>
  );
}

// The header slot lives inside Pierre's file header. Stop the pointer
// sequence at the action cluster so a button press never reaches the header
// (its line-selection handling, or a header toggle should the library add
// one). Keys pass through, except the two that would activate the header:
// the document-level Escape and Cmd+F listeners must still see a key pressed
// on these buttons.
function stopHeaderPropagation(event: React.SyntheticEvent): void {
  event.stopPropagation();
}

function stopHeaderToggleKeys(event: React.KeyboardEvent): void {
  if (event.key === "Enter" || event.key === " ") {
    event.stopPropagation();
  }
}

/**
 * The card's selection checkbox, slotted after the fold chevron where the
 * library's file-type icon would sit (the code view's CSS hides that icon).
 * It mirrors the file list's row checkbox: both toggle
 * the same path in the App's selection, and neither navigates. A native
 * checkbox, so the header's own click handling is stopped at it.
 */
export function FileSelectCheckbox({ checked, label, onToggle }: {
  checked: boolean;
  /** The accessible name, already naming the file ("Select story.txt"). */
  label: string;
  onToggle: () => void;
}) {
  return (
    <input
      type="checkbox"
      className="file-select-checkbox"
      aria-label={label}
      title={label}
      checked={checked}
      onChange={onToggle}
      onClick={stopHeaderPropagation}
      onPointerDown={stopHeaderPropagation}
      onKeyDown={stopHeaderToggleKeys}
    />
  );
}

export function FileWriteActions({
  actions,
  label,
  onAction,
  onCopyPath,
  onOpenInCmux,
  pending,
}: {
  actions: readonly FileWriteAction[];
  label: DiffViewerLabelResolver;
  onAction: (action: FileWriteAction) => void;
  /** Copies the repository-relative path; always offered when present. */
  onCopyPath?: () => void;
  /** Opens the file in the hosting workspace; offered only on a host transport. */
  onOpenInCmux?: () => void;
  pending: boolean;
}) {
  const [confirming, setConfirming] = useState(false);
  if (actions.length === 0 && onCopyPath == null && onOpenInCmux == null) {
    return null;
  }
  return (
    // oxlint-disable-next-line jsx-a11y/no-static-element-interactions, jsx-a11y/click-events-have-key-events
    <span
      className="worktree-file-actions"
      data-pending={pending ? "true" : "false"}
      onClick={stopHeaderPropagation}
      onPointerDown={stopHeaderPropagation}
      onKeyDown={stopHeaderToggleKeys}
    >
      {confirming ? (
        <InlineConfirmation
          confirmLabel={label("confirmRevert")}
          onCancel={() => setConfirming(false)}
          onConfirm={() => {
            setConfirming(false);
            onAction("revertFile");
          }}
          pending={pending}
          prompt={label("revertPrompt")}
          cancelLabel={label("cancel")}
        />
      ) : (
        <>
          {onOpenInCmux ? (
            <WorktreeActionButton
              action="openInCmux"
              icon="open"
              label={label("openInCmux")}
              onClick={onOpenInCmux}
            />
          ) : null}
          {onCopyPath ? (
            <WorktreeActionButton
              action="copyPath"
              icon="clipboard"
              label={label("copyPath")}
              onClick={onCopyPath}
            />
          ) : null}
          {actions.map((action) => (
            <WorktreeActionButton
              key={action}
              action={action}
              icon={FILE_ACTION_ICON[action]}
              label={label(action)}
              disabled={pending}
              onClick={() =>
                action === "revertFile" ? setConfirming(true) : onAction(action)
              }
            />
          ))}
        </>
      )}
    </span>
  );
}

/**
 * One icon button of the per-file action cluster. The write actions pass
 * `pending`; the utilities (open, copy path) never mutate, so they stay
 * enabled.
 */
function WorktreeActionButton({
  action,
  disabled,
  icon,
  label,
  onClick,
}: {
  action: string;
  disabled?: boolean;
  icon: IconName;
  label: string;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      className="worktree-action"
      data-action={action}
      disabled={disabled}
      title={label}
      aria-label={label}
      onClick={onClick}
    >
      <Icon name={icon} />
    </button>
  );
}

export function HunkWriteActions({
  label,
  onRevert,
  pending,
}: {
  label: DiffViewerLabelResolver;
  onRevert: () => void;
  pending: boolean;
}) {
  const [confirming, setConfirming] = useState(false);
  return (
    <div
      className="worktree-hunk-actions"
      data-pending={pending ? "true" : "false"}
    >
      {confirming ? (
        <InlineConfirmation
          confirmLabel={label("confirmRevert")}
          onCancel={() => setConfirming(false)}
          onConfirm={() => {
            setConfirming(false);
            onRevert();
          }}
          pending={pending}
          prompt={label("revertPrompt")}
          cancelLabel={label("cancel")}
        />
      ) : (
        <button
          type="button"
          className="worktree-hunk-button"
          disabled={pending}
          title={label("revertHunk")}
          onClick={() => setConfirming(true)}
        >
          <Icon name="revert" />
          <span>{label("revertHunk")}</span>
        </button>
      )}
    </div>
  );
}

/**
 * Inline confirm row for a destructive action: prompt, a danger-styled
 * confirm button, and cancel. Native buttons only; it never traps focus.
 */
export function InlineConfirmation({
  cancelLabel,
  confirmLabel,
  onCancel,
  onConfirm,
  pending,
  prompt,
}: {
  cancelLabel: string;
  confirmLabel: string;
  onCancel: () => void;
  onConfirm: () => void;
  pending: boolean;
  prompt: string;
}) {
  return (
    <span className="worktree-confirm">
      <span className="worktree-confirm-text">{prompt}</span>
      <button
        type="button"
        className="worktree-confirm-button worktree-confirm-danger"
        data-action="confirm"
        disabled={pending}
        onClick={onConfirm}
      >
        {confirmLabel}
      </button>
      <button
        type="button"
        className="worktree-confirm-button"
        data-action="cancel"
        onClick={onCancel}
      >
        {cancelLabel}
      </button>
    </span>
  );
}

export function CommitPopover({
  availability,
  label,
  onCancel,
  onCommit,
  pending,
}: {
  availability: Exclude<CommitAvailability, "hidden">;
  label: DiffViewerLabelResolver;
  onCancel: () => void;
  /** `stageAll` is true when the unstaged view asked to stage everything first. */
  onCommit: (message: string, stageAll: boolean) => void;
  pending: boolean;
}) {
  const [message, setMessage] = useState("");
  // Full validation (UTF-8 length) runs on submit and blur, not per keystroke;
  // the Commit button only needs to know whether there is any text at all.
  const [validation, setValidation] = useState<CommitMessageValidation | null>(
    null,
  );
  const blank = message.trim() === "";
  const invalid = validation != null && !validation.ok;
  const stageAll = availability === "stageAll";
  const validate = () => {
    const next = validateCommitMessage(message);
    setValidation(next);
    return next;
  };
  const submit = () => {
    const next = validate();
    if (next.ok && !pending) {
      onCommit(next.message, stageAll);
    }
  };
  // Callback ref: the textarea mounts with the popover, so focusing here gives
  // open-time focus without the a11y-flagged autoFocus attribute. Stable, so
  // React does not detach and reattach (and refocus) it on every keystroke.
  const focusInput = useCallback((node: HTMLTextAreaElement | null) => {
    node?.focus();
  }, []);
  // Escape is handled once, by `useCommitPopoverDismiss`'s document listener.
  return (
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
    <div id="commit-popover" role="dialog" aria-label={label("commitChanges")}>
      <textarea
        ref={focusInput}
        className="commit-message-input"
        placeholder={label("commitMessagePlaceholder")}
        aria-label={label("commitMessagePlaceholder")}
        aria-invalid={invalid}
        value={message}
        disabled={pending}
        onChange={(event) => {
          setMessage(event.currentTarget.value);
          setValidation(null);
        }}
        onBlur={validate}
        onKeyDown={(event) => {
          if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
            event.preventDefault();
            submit();
          }
        }}
      />
      <div className="commit-popover-footer">
        <span className="commit-popover-hint" aria-live="polite">
          {invalid ? label("commitMessageInvalid") : ""}
        </span>
        <span className="commit-popover-buttons">
          <button type="button" className="comment-button" onClick={onCancel}>
            {label("cancel")}
          </button>
          <button
            type="button"
            className="comment-button comment-button-primary"
            data-stage-all={stageAll ? "true" : "false"}
            disabled={pending || blank || invalid}
            onClick={submit}
          >
            {stageAll ? label("stageAllAndCommit") : label("commitSubmit")}
          </button>
        </span>
      </div>
    </div>
  );
}

const PULL_REQUEST_VALIDATION_LABEL: Record<
  Extract<PullRequestValidation, { ok: false }>["reason"],
  DiffViewerLabelKey
> = {
  emptyTitle: "pullRequestTitleInvalid",
  titleTooLong: "pullRequestTitleInvalid",
  bodyTooLong: "pullRequestBodyInvalid",
  invalidBase: "pullRequestBaseInvalid",
};

export function PullRequestPopover({
  hostKind,
  label,
  onCancel,
  onCreate,
  pending,
}: {
  hostKind: RepositoryHostKind | null;
  label: DiffViewerLabelResolver;
  onCancel: () => void;
  onCreate: (draft: PullRequestDraft) => void;
  pending: boolean;
}) {
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [base, setBase] = useState("");
  const [draft, setDraft] = useState(false);
  const [validation, setValidation] = useState<PullRequestValidation | null>(
    null,
  );
  const keys = pullRequestLabelKeys(hostKind);
  // The last submit's verdict when it failed, until the next edit clears it.
  const failure = validation != null && !validation.ok ? validation : null;
  const validate = () => {
    const next = validatePullRequestDraft({ title, body, draft, base });
    setValidation(next);
    return next;
  };
  const submit = () => {
    const next = validate();
    if (next.ok && !pending) {
      onCreate(next.draft);
    }
  };
  const focusInput = useCallback((node: HTMLInputElement | null) => {
    node?.focus();
  }, []);
  return (
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
    <div id="pull-request-popover" role="dialog" aria-label={label(keys.dialog)}>
      <input
        ref={focusInput}
        className="pull-request-title-input"
        type="text"
        placeholder={label("pullRequestTitlePlaceholder")}
        aria-label={label("pullRequestTitlePlaceholder")}
        aria-invalid={
          failure != null &&
          failure.reason !== "bodyTooLong" &&
          failure.reason !== "invalidBase"
        }
        value={title}
        disabled={pending}
        onChange={(event) => {
          setTitle(event.currentTarget.value);
          setValidation(null);
        }}
        onKeyDown={(event) => {
          if (event.key === "Enter") {
            event.preventDefault();
            submit();
          }
        }}
      />
      <textarea
        className="commit-message-input pull-request-body-input"
        placeholder={label("pullRequestBodyPlaceholder")}
        aria-label={label("pullRequestBodyPlaceholder")}
        value={body}
        disabled={pending}
        onChange={(event) => {
          setBody(event.currentTarget.value);
          setValidation(null);
        }}
        onKeyDown={(event) => {
          if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
            event.preventDefault();
            submit();
          }
        }}
      />
      <div className="pull-request-options">
        <input
          className="pull-request-base-input"
          type="text"
          placeholder={label("pullRequestBasePlaceholder")}
          aria-label={label("pullRequestBasePlaceholder")}
          aria-invalid={failure?.reason === "invalidBase"}
          value={base}
          disabled={pending}
          onChange={(event) => {
            setBase(event.currentTarget.value);
            setValidation(null);
          }}
        />
        <label className="pull-request-draft-toggle">
          <input
            type="checkbox"
            aria-label={label("pullRequestDraft")}
            checked={draft}
            disabled={pending}
            onChange={(event) => setDraft(event.currentTarget.checked)}
          />
          <span>{label("pullRequestDraft")}</span>
        </label>
      </div>
      <div className="commit-popover-footer">
        <span className="commit-popover-hint" aria-live="polite">
          {failure ? label(PULL_REQUEST_VALIDATION_LABEL[failure.reason]) : ""}
        </span>
        <span className="commit-popover-buttons">
          <button type="button" className="comment-button" onClick={onCancel}>
            {label("cancel")}
          </button>
          <button
            type="button"
            className="comment-button comment-button-primary"
            data-action="createPullRequest"
            disabled={pending || title.trim() === "" || failure != null}
            onClick={submit}
          >
            {label(keys.submit)}
          </button>
        </span>
      </div>
    </div>
  );
}

/**
 * Summary of the branch's pull (merge) request. The URL opens externally
 * through the host's popup policy (`target="_blank"`), never inside the viewer.
 */
export function PullRequestCard({
  hostKind,
  label,
  request,
}: {
  hostKind: RepositoryHostKind | null;
  label: DiffViewerLabelResolver;
  request: PullRequestSummary;
}) {
  const keys = pullRequestLabelKeys(hostKind);
  const url = externalPullRequestURL(request.url);
  const state = pullRequestStateLabelKey(request);
  const review = reviewDecisionLabelKey(request.reviewDecision);
  const checks = request.checks;
  return (
    <section
      id="pull-request-card"
      aria-label={label(keys.open)}
      data-state={request.state}
    >
      <span className="pull-request-number">#{request.number}</span>
      <span className="pull-request-state" data-state={state}>
        {label(state)}
      </span>
      <span className="pull-request-title">{request.title}</span>
      {request.baseBranch ? (
        <span className="pull-request-base">
          {formatLabel(label("pullRequestBase"), { base: request.baseBranch })}
        </span>
      ) : null}
      {checks != null && checks.total > 0 ? (
        <span
          className="pull-request-checks"
          data-failed={checks.failed > 0 ? "true" : "false"}
          data-pending={checks.pending > 0 ? "true" : "false"}
        >
          {formatLabel(label("checksPassed"), {
            passed: checks.passed,
            total: checks.total,
          })}
          {checks.failed > 0
            ? ` · ${formatLabel(label("checksFailed"), { count: checks.failed })}`
            : ""}
          {checks.pending > 0
            ? ` · ${formatLabel(label("checksPending"), { count: checks.pending })}`
            : ""}
        </span>
      ) : null}
      {review ? (
        <span
          className="pull-request-review"
          data-decision={request.reviewDecision ?? ""}
        >
          {label(review)}
        </span>
      ) : null}
      {url ? (
        <a
          className="pull-request-link toolbar-icon"
          href={url}
          target="_blank"
          rel="noreferrer"
          title={label(keys.open)}
          aria-label={label(keys.open)}
        >
          <Icon name="external" />
        </a>
      ) : null}
    </section>
  );
}

/**
 * Transient outcome notice for write actions. Errors stay until the next
 * action; successes fade after a few seconds.
 */
export type WorktreeNotice = {
  error: boolean;
  message: string;
  token: number;
};

export function WorktreeNoticeView({
  notice,
  onExpire,
}: {
  notice: WorktreeNotice | null;
  onExpire: (token: number) => void;
}) {
  useEffect(() => {
    if (notice == null || notice.error) {
      return;
    }
    const handle = setTimeout(() => onExpire(notice.token), 4000);
    return () => clearTimeout(handle);
  }, [notice, onExpire]);
  if (notice == null) {
    return null;
  }
  return (
    <output
      id="worktree-notice"
      className="worktree-notice"
      data-error={notice.error ? "true" : "false"}
    >
      {notice.message}
    </output>
  );
}

/**
 * Closes an open popover or menu on an outside click or Escape. `within`
 * is the selector of the element cluster (trigger plus popover) that counts
 * as inside.
 */
export function useDismissOnOutsideInteraction(
  open: boolean,
  onClose: () => void,
  within: string,
): void {
  useEffect(() => {
    if (!open) {
      return;
    }
    const closeOnOutsideClick = (event: MouseEvent) => {
      if (event.target instanceof Element && event.target.closest(within)) {
        return;
      }
      onClose();
    };
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        onClose();
      }
    };
    document.addEventListener("mousedown", closeOnOutsideClick);
    document.addEventListener("keydown", closeOnEscape);
    return () => {
      document.removeEventListener("mousedown", closeOnOutsideClick);
      document.removeEventListener("keydown", closeOnEscape);
    };
  }, [onClose, open, within]);
}
