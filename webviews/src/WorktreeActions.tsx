import { useCallback, useEffect, useState } from "react";
import { Icon, type IconName } from "./icons";
import type { DiffViewerLabelResolver } from "./labels";
import {
  validateCommitMessage,
  type CommitAvailability,
  type CommitMessageValidation,
  type FileWriteAction,
} from "./worktree-actions";

/**
 * Write-action controls for the diff viewer: per-file header buttons, the
 * per-hunk action row, and the toolbar Commit button with its popover. Every
 * destructive action (revert) asks for an inline confirmation first; nothing
 * here talks to the transport, the App owns the request and the reload.
 */

const FILE_ACTION_ICON: Record<FileWriteAction, IconName> = {
  revertFile: "revert",
  stageFile: "stage",
  unstageFile: "unstage",
};

// The header slot lives inside Pierre's clickable file header, whose click
// toggles collapse. Stop the pointer sequence at the action cluster so a
// button press never doubles as a header toggle. Keys pass through, except
// the two that would activate the header: the document-level Escape and
// Cmd+F listeners must still see a key pressed on these buttons.
function stopHeaderPropagation(event: React.SyntheticEvent): void {
  event.stopPropagation();
}

function stopHeaderToggleKeys(event: React.KeyboardEvent): void {
  if (event.key === "Enter" || event.key === " ") {
    event.stopPropagation();
  }
}

export function FileWriteActions({
  actions,
  label,
  onAction,
  pending,
}: {
  actions: readonly FileWriteAction[];
  label: DiffViewerLabelResolver;
  onAction: (action: FileWriteAction) => void;
  pending: boolean;
}) {
  const [confirming, setConfirming] = useState(false);
  if (actions.length === 0) {
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
        <RevertConfirmation
          label={label}
          onCancel={() => setConfirming(false)}
          onConfirm={() => {
            setConfirming(false);
            onAction("revertFile");
          }}
          pending={pending}
        />
      ) : (
        actions.map((action) => (
          <button
            key={action}
            type="button"
            className="worktree-action"
            data-action={action}
            disabled={pending}
            title={label(action)}
            aria-label={label(action)}
            onClick={() =>
              action === "revertFile" ? setConfirming(true) : onAction(action)
            }
          >
            <Icon name={FILE_ACTION_ICON[action]} />
          </button>
        ))
      )}
    </span>
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
        <RevertConfirmation
          label={label}
          onCancel={() => setConfirming(false)}
          onConfirm={() => {
            setConfirming(false);
            onRevert();
          }}
          pending={pending}
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

function RevertConfirmation({
  label,
  onCancel,
  onConfirm,
  pending,
}: {
  label: DiffViewerLabelResolver;
  onCancel: () => void;
  onConfirm: () => void;
  pending: boolean;
}) {
  return (
    <span className="worktree-confirm">
      <span className="worktree-confirm-text">{label("revertPrompt")}</span>
      <button
        type="button"
        className="worktree-confirm-button worktree-confirm-danger"
        disabled={pending}
        onClick={onConfirm}
      >
        {label("confirmRevert")}
      </button>
      <button
        type="button"
        className="worktree-confirm-button"
        onClick={onCancel}
      >
        {label("cancel")}
      </button>
    </span>
  );
}

export function CommitButton({
  availability,
  label,
  onToggle,
  open,
  pending,
}: {
  availability: Exclude<CommitAvailability, "hidden">;
  label: DiffViewerLabelResolver;
  onToggle: () => void;
  open: boolean;
  pending: boolean;
}) {
  const enabled = availability === "enabled" && !pending;
  const title =
    availability === "requiresStaged"
      ? label("commitRequiresStaged")
      : label("commitChanges");
  return (
    <button
      id="commit-button"
      type="button"
      disabled={!enabled}
      title={title}
      aria-label={title}
      aria-expanded={open}
      aria-controls="commit-popover"
      data-availability={availability}
      onClick={onToggle}
    >
      <Icon name="commit" />
      <span className="commit-button-label">{label("commitSubmit")}</span>
    </button>
  );
}

export function CommitPopover({
  label,
  onCancel,
  onCommit,
  pending,
}: {
  label: DiffViewerLabelResolver;
  onCancel: () => void;
  onCommit: (message: string) => void;
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
  const validate = () => {
    const next = validateCommitMessage(message);
    setValidation(next);
    return next;
  };
  const submit = () => {
    const next = validate();
    if (next.ok && !pending) {
      onCommit(next.message);
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
            disabled={pending || blank || invalid}
            onClick={submit}
          >

            {label("commitSubmit")}
          </button>
        </span>
      </div>
    </div>
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

/** Closes the popover on an outside click or Escape while it is open. */
export function useCommitPopoverDismiss(
  open: boolean,
  onClose: () => void,
): void {
  useEffect(() => {
    if (!open) {
      return;
    }
    const closeOnOutsideClick = (event: MouseEvent) => {
      if (
        event.target instanceof Element &&
        event.target.closest("#commit-popover, #commit-button")
      ) {
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
  }, [onClose, open]);
}
