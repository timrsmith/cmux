//! Working-tree and index mutations for open `unstaged` and `staged` sessions.
//!
//! Every command re-derives its inputs on the sidecar side: paths are
//! validated as repository-relative and must already be known to Git (in the
//! index, or for an unstage or staged revert also in HEAD), hunks are re-read
//! from `git diff` and matched by header before `git apply -R` runs, and
//! nothing supplied by the page is ever passed to Git as patch text.
//! Authorization requires a valid capability token, a repository in that
//! token's allow-list, and an open session owned by the token whose
//! repository and source kind are the ones being mutated.

use std::borrow::Cow;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::process::ExitStatus;
use std::time::Duration;

use crate::forge::{self, FORGE_CLI_TIMEOUT, ForgeCli};
use crate::git::{self, Access};
use crate::manifest::valid_token;
use crate::protocol::{
    CommitResult, DiffResult, DiffSource, DiffSourceKind, ForgeCliKind, ForgeCliStatus, HunkRef,
    PullRequestCreated, PushResult, RepositoryHostKind, RepositoryStatus, WorktreeCommitRequest,
    WorktreeCreatePullRequestRequest, WorktreeFileRequest, WorktreeFilesRequest,
    WorktreeHunkRequest, WorktreeMutated, WorktreePushRequest, WorktreeSessionRequest,
};
use crate::server::{
    AppState, authorize_canonical_repo_for_token, manifest_files, read_session_owner,
    session_request_path,
};

pub(crate) const MAX_COMMIT_MESSAGE_BYTES: usize = 64 * 1024;
pub(crate) const MAX_PULL_REQUEST_TITLE_BYTES: usize = 256;
pub(crate) const MAX_PULL_REQUEST_BODY_BYTES: usize = 64 * 1024;
const MAX_REF_NAME_BYTES: usize = 256;
const MAX_REPO_RELATIVE_PATH_BYTES: usize = 4096;
// Paths one selection action may name. A request is already bounded to one
// MiB; this keeps the listings and the pathspec stream a page can ask for
// proportional to something a person selected rather than to that limit.
pub(crate) const MAX_BATCH_PATHS: usize = 10_000;
// Read-only listings take their pathspecs on the command line, so a batch is
// walked in chunks that stay well under the argument-length limit even when
// every path is at its maximum length.
const MAX_LISTING_PATHSPEC_BYTES: usize = 128 * 1024;
// One file's unified diff is re-read to select a hunk; anything larger is
// not something a per-hunk action should be reverting.
const MAX_HUNK_DIFF_BYTES: usize = 32 * 1024 * 1024;
// Path listings and status-style output (`ls-files`, `rev-parse`) for a
// handful of paths; reaching this means Git is not answering the question.
const MAX_STATUS_OUTPUT_BYTES: usize = 1024 * 1024;
// A whole session's changed-path listing (`diff --name-status -z`), which a
// bulk action walks; well past any repository a diff viewer renders.
const MAX_PATH_LISTING_BYTES: usize = 64 * 1024 * 1024;
// Hook output kept from a failed commit, and the slice of it surfaced.
const MAX_HOOK_STDERR_BYTES: usize = 16 * 1024;
const MAX_HOOK_DETAIL_CHARS: usize = 200;
/// `git push` talks to the network; credential helpers and SSH agents need
/// longer than a local query but must still give up eventually.
pub(crate) const PUSH_TIMEOUT: Duration = Duration::from_secs(120);
/// One deadline for the whole pull request flow (`auth status`, the implicit
/// push, the request lookup, `pr create`): the flow runs under a single
/// `tokio::time::timeout`, so the chain stays under the server's
/// `NETWORK_ACTION_TIMEOUT` instead of adding its steps' budgets together.
/// Each step keeps its own maximum (`FORGE_CLI_TIMEOUT`, `PUSH_TIMEOUT`).
pub(crate) const PULL_REQUEST_FLOW_BUDGET: Duration = Duration::from_secs(115);

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum WriteError {
    NotAllowed,
    InvalidPath,
    InvalidMessage,
    StaleHunk,
    Conflict,
    /// A staged revert changed the index but could not finish in the working
    /// tree; the page must reload to show the resulting split state.
    PartialRevert,
    NothingToCommit,
    CommitFailed,
    /// Git refused the commit and said why (typically a hook); the detail is
    /// the last line of its stderr, bounded.
    CommitRejected(String),
    /// A push or pull request needs a branch, and HEAD is detached.
    DetachedHead,
    /// The branch has no upstream and the caller did not ask to create one.
    NoUpstream,
    /// Git or the forge CLI could not authenticate (no credentials, or a
    /// prompt it was forbidden to show).
    AuthRequired,
    /// The remote refused the push (non-fast-forward, hook, missing remote);
    /// the detail is the last stderr line when there was one.
    PushRejected(Option<String>),
    /// The remote is a forge but its CLI is not installed.
    ForgeCliMissing,
    /// The forge CLI is installed but not signed in.
    ForgeNotAuthenticated,
    /// A pull request already exists for the branch (its URL when known).
    PullRequestExists(Option<String>),
    /// The forge CLI refused to create the request; bounded last stderr line.
    PullRequestCreateFailed(Option<String>),
    InvalidTitle,
    InvalidBody,
    InvalidBase,
    Failed,
}

impl WriteError {
    pub(crate) fn code(&self) -> &'static str {
        match self {
            Self::NotAllowed => "notAllowed",
            Self::InvalidPath => "invalidPath",
            Self::InvalidMessage => "invalidMessage",
            Self::StaleHunk => "staleHunk",
            Self::Conflict => "conflict",
            Self::PartialRevert => "partialRevert",
            Self::NothingToCommit => "nothingToCommit",
            Self::CommitFailed | Self::CommitRejected(_) => "commitFailed",
            Self::DetachedHead => "detachedHead",
            Self::NoUpstream => "noUpstream",
            Self::AuthRequired => "authRequired",
            Self::PushRejected(_) => "pushRejected",
            Self::ForgeCliMissing => "forgeCliMissing",
            Self::ForgeNotAuthenticated => "forgeNotAuthenticated",
            Self::PullRequestExists(_) => "pullRequestExists",
            Self::PullRequestCreateFailed(_) => "pullRequestCreateFailed",
            Self::InvalidTitle => "invalidTitle",
            Self::InvalidBody => "invalidBody",
            Self::InvalidBase => "invalidBase",
            Self::Failed => "worktreeWriteFailed",
        }
    }

    pub(crate) fn message(&self) -> Cow<'static, str> {
        match self {
            Self::NotAllowed => "Working-tree change is not authorized".into(),
            Self::InvalidPath => "Path must be relative to the repository".into(),
            Self::InvalidMessage => "Commit message is empty or too long".into(),
            Self::StaleHunk => "The hunk no longer matches the working tree".into(),
            Self::Conflict => "The change could not be applied cleanly".into(),
            Self::PartialRevert => {
                "The change was unstaged but could not be removed from the working tree".into()
            }
            Self::NothingToCommit => "There are no staged changes to commit".into(),
            Self::CommitFailed => "Git could not create the commit".into(),
            Self::CommitRejected(detail) => {
                format!("Git could not create the commit: {detail}").into()
            }
            Self::DetachedHead => "HEAD is detached; check out a branch first".into(),
            Self::NoUpstream => "The branch has no upstream".into(),
            Self::AuthRequired => "Git could not authenticate with the remote".into(),
            Self::PushRejected(None) => "The remote rejected the push".into(),
            Self::PushRejected(Some(detail)) => {
                format!("The remote rejected the push: {detail}").into()
            }
            Self::ForgeCliMissing => "The forge command-line tool is not installed".into(),
            Self::ForgeNotAuthenticated => "The forge command-line tool is not signed in".into(),
            Self::PullRequestExists(None) => "A pull request already exists for this branch".into(),
            Self::PullRequestExists(Some(url)) => {
                format!("A pull request already exists for this branch: {url}").into()
            }
            Self::PullRequestCreateFailed(None) => "Could not create the pull request".into(),
            Self::PullRequestCreateFailed(Some(detail)) => {
                format!("Could not create the pull request: {detail}").into()
            }
            Self::InvalidTitle => "Pull request title is empty or too long".into(),
            Self::InvalidBody => "Pull request description is too long".into(),
            Self::InvalidBase => "Base branch name is not valid".into(),
            Self::Failed => "Could not update the working tree".into(),
        }
    }
}

/// A refused or failed write, and whether the repository may no longer match
/// the diff the page rendered. The flag is set once a mutating child has been
/// spawned (Git may have changed some paths before exiting non-zero for
/// another) and for the errors that mean the diff changed under the page
/// (`StaleHunk`, `Conflict`, `PartialRevert`); the page reloads on it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct WriteFailure {
    pub(crate) error: WriteError,
    pub(crate) state_may_have_changed: bool,
}

impl From<WriteError> for WriteFailure {
    fn from(error: WriteError) -> Self {
        let state_may_have_changed = matches!(
            error,
            WriteError::StaleHunk | WriteError::Conflict | WriteError::PartialRevert
        );
        Self {
            error,
            state_may_have_changed,
        }
    }
}

impl WriteFailure {
    /// `error`, raised after a mutating child ran.
    fn after_write(error: WriteError) -> Self {
        Self {
            error,
            state_may_have_changed: true,
        }
    }
}

struct Target {
    repo: PathBuf,
    staged: bool,
}

#[derive(Clone, Copy)]
enum FileOp {
    Revert,
    Stage,
    Unstage,
}

pub(crate) async fn revert_file(
    state: &AppState,
    request: &WorktreeFileRequest,
) -> Result<DiffResult, WriteFailure> {
    file_op(state, request, FileOp::Revert).await
}

pub(crate) async fn stage_file(
    state: &AppState,
    request: &WorktreeFileRequest,
) -> Result<DiffResult, WriteFailure> {
    file_op(state, request, FileOp::Stage).await
}

pub(crate) async fn unstage_file(
    state: &AppState,
    request: &WorktreeFileRequest,
) -> Result<DiffResult, WriteFailure> {
    file_op(state, request, FileOp::Unstage).await
}

/// One file: the single-file request is the batch of that file's path(s).
async fn file_op(
    state: &AppState,
    request: &WorktreeFileRequest,
    op: FileOp,
) -> Result<DiffResult, WriteFailure> {
    let _permit = permit(state)?;
    let target = authorize(
        state,
        &request.session_id,
        &request.capability_token,
        &request.source,
    )
    .await?;
    let paths = file_paths(request)?;
    apply_file_op(&target, &paths, op).await?;
    Ok(mutated(&request.source))
}

pub(crate) async fn stage_files(
    state: &AppState,
    request: &WorktreeFilesRequest,
) -> Result<DiffResult, WriteFailure> {
    files_op(state, request, FileOp::Stage).await
}

pub(crate) async fn unstage_files(
    state: &AppState,
    request: &WorktreeFilesRequest,
) -> Result<DiffResult, WriteFailure> {
    files_op(state, request, FileOp::Unstage).await
}

pub(crate) async fn discard_files(
    state: &AppState,
    request: &WorktreeFilesRequest,
) -> Result<DiffResult, WriteFailure> {
    files_op(state, request, FileOp::Revert).await
}

/// A selection of files, acted on with one Git invocation per step (the same
/// steps the single-file action takes). Every path is validated before
/// anything runs, so a refused path leaves the repository untouched.
async fn files_op(
    state: &AppState,
    request: &WorktreeFilesRequest,
    op: FileOp,
) -> Result<DiffResult, WriteFailure> {
    let _permit = permit(state)?;
    let target = authorize(
        state,
        &request.session_id,
        &request.capability_token,
        &request.source,
    )
    .await?;
    let paths = batch_paths(&request.paths)?;
    apply_file_op(&target, &paths, op).await?;
    Ok(mutated(&request.source))
}

/// The shared core of the per-file and per-selection actions. Every path
/// must already be known to Git (see each arm); a `git diff` session lists
/// tracked files only, so an unknown path can only come from the page and is
/// refused before any Git child runs.
async fn apply_file_op(target: &Target, paths: &[String], op: FileOp) -> Result<(), WriteFailure> {
    match op {
        FileOp::Stage => {
            // A path outside the index can only come from the page; staging
            // it would add an arbitrary untracked file.
            let in_index = index_paths(&target.repo, paths).await?;
            require_all(paths, &in_index)?;
            run_over_paths(&target.repo, &["add"], paths).await
        }
        FileOp::Unstage => {
            // A staged deletion has no index entry but is in HEAD, which is
            // where `restore --staged` takes it from.
            let mut known = index_paths(&target.repo, paths).await?;
            known.extend(head_paths(&target.repo, paths).await?);
            require_all(paths, &known)?;
            run_over_paths(&target.repo, &["restore", "--staged"], paths).await
        }
        FileOp::Revert => revert_paths(target, paths).await,
    }
}

pub(crate) async fn revert_hunk(
    state: &AppState,
    request: &WorktreeHunkRequest,
) -> Result<DiffResult, WriteFailure> {
    let _permit = permit(state)?;
    let target = authorize(
        state,
        &request.session_id,
        &request.capability_token,
        &request.source,
    )
    .await?;
    let path = validate_repo_relative_path(&request.path)?;
    let previous_path = request
        .previous_path
        .as_deref()
        .map(validate_repo_relative_path)
        .transpose()?;
    // Re-read the file's diff the way the session patch was produced (default
    // rename detection, so a staged rename with edits still finds its hunks),
    // with the prefixes pinned so `diff.noprefix` or `diff.mnemonicPrefix`
    // cannot produce a header `git apply -R` misreads. A rename needs both
    // names in the pathspec or Git sees a plain addition.
    let mut arguments = vec![
        "diff",
        "--no-ext-diff",
        "--no-color",
        "--src-prefix=a/",
        "--dst-prefix=b/",
    ];
    if target.staged {
        arguments.push("--cached");
    }
    arguments.push("--");
    let pathspecs: Vec<String> = [Some(path), previous_path]
        .into_iter()
        .flatten()
        .map(literal_pathspec)
        .collect();
    arguments.extend(pathspecs.iter().map(String::as_str));
    let (diff, status) = git::capture(
        &target.repo,
        &arguments,
        Access::ReadOnly,
        None,
        MAX_HUNK_DIFF_BYTES,
    )
    .await
    .map_err(|()| WriteError::Failed)?;
    if !status.success() {
        return Err(WriteError::Failed.into());
    }
    let reverse_patch =
        select_hunk_patch(&diff, request.hunk, path).ok_or(WriteError::StaleHunk)?;
    let apply = ["apply", "-R", "--whitespace=nowarn"];
    if !target.staged {
        return if apply_patch(&target.repo, &apply, &reverse_patch).await? {
            Ok(mutated(&request.source))
        } else {
            Err(WriteError::Conflict.into())
        };
    }
    // Reverting a staged hunk means "unstage it and discard it": first the
    // index, then the working tree when it still carries the same change.
    // `--index` would refuse whenever the two differ at all, which is the
    // partially staged file this action exists for.
    if !apply_patch(
        &target.repo,
        &["apply", "-R", "--whitespace=nowarn", "--cached"],
        &reverse_patch,
    )
    .await?
    {
        return Err(WriteError::Conflict.into());
    }
    if apply_patch(&target.repo, &apply, &reverse_patch)
        .await
        .map_err(WriteFailure::after_write)?
    {
        Ok(mutated(&request.source))
    } else {
        Err(WriteError::PartialRevert.into())
    }
}

pub(crate) async fn commit(
    state: &AppState,
    request: &WorktreeCommitRequest,
) -> Result<DiffResult, WriteFailure> {
    let _permit = permit(state)?;
    let target = authorize(
        state,
        &request.session_id,
        &request.capability_token,
        &request.source,
    )
    .await?;
    // A commit only ever records the index. An unstaged session may ask for
    // its tracked changes to be staged first (one authorization, one action);
    // without that it has nothing of its own to commit.
    if !target.staged && !request.stage_all {
        return Err(WriteError::NotAllowed.into());
    }
    let message = request.message.trim();
    if message.is_empty() || message.len() > MAX_COMMIT_MESSAGE_BYTES {
        return Err(WriteError::InvalidMessage.into());
    }
    if request.stage_all {
        stage_tracked_changes(&target.repo).await?;
        // `add --update` has run: whatever refuses the commit now leaves the
        // index changed under the page.
        return commit_index(&target.repo, message)
            .await
            .map_err(WriteFailure::after_write);
    }
    Ok(commit_index(&target.repo, message).await?)
}

/// Records the index as a commit with `message`: nothing staged is
/// `NothingToCommit`, a hook's refusal is `CommitRejected` with its last
/// line, and the new HEAD comes back verified as a hex object name.
async fn commit_index(repo: &Path, message: &str) -> Result<DiffResult, WriteError> {
    match git_status(
        repo,
        &["diff", "--cached", "--quiet"],
        Access::ReadOnly,
        None,
    )
    .await?
    .code()
    {
        Some(0) => return Err(WriteError::NothingToCommit),
        Some(1) => {}
        _ => return Err(WriteError::Failed),
    }
    let mut body = message.as_bytes().to_vec();
    body.push(b'\n');
    // Hooks run inside this command; it gets its own process group so a hung
    // hook dies with the deadline, and its stderr explains a refusal.
    let (_, stderr, status) = git::capture_with_hooks(
        repo,
        &["commit", "--quiet", "--cleanup=whitespace", "-F", "-"],
        Some(&body),
        MAX_STATUS_OUTPUT_BYTES,
        MAX_HOOK_STDERR_BYTES,
    )
    .await
    .map_err(|()| WriteError::Failed)?;
    if !status.success() {
        return Err(commit_rejection(&stderr));
    }
    let commit = git::single_line(repo, &["rev-parse", "--verify", "HEAD"])
        .await
        .map_err(|()| WriteError::Failed)?;
    if !(40..=64).contains(&commit.len()) || !commit.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(WriteError::Failed);
    }
    Ok(DiffResult::Committed(CommitResult { commit }))
}

/// The error for a failed `git commit`: its last stderr line (a hook's
/// verdict, or Git's own reason), printable characters only and bounded, or
/// the generic failure when it said nothing.
fn commit_rejection(stderr: &[u8]) -> WriteError {
    match last_stderr_line(stderr) {
        Some(detail) => WriteError::CommitRejected(detail),
        None => WriteError::CommitFailed,
    }
}

/// The last non-empty line of a child's stderr (progress output separates
/// lines with CR as well as LF), control characters stripped and bounded to
/// [`MAX_HOOK_DETAIL_CHARS`]. `None` when nothing printable was said.
fn last_stderr_line(stderr: &[u8]) -> Option<String> {
    let text = String::from_utf8_lossy(stderr);
    let line = text
        .split(['\n', '\r'])
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .next_back()?;
    let detail: String = line
        .chars()
        .filter(|character| !character.is_control())
        .take(MAX_HOOK_DETAIL_CHARS)
        .collect();
    (!detail.trim().is_empty()).then_some(detail)
}

// MARK: Bulk actions

/// Discards every change the session shows. An unstaged session restores
/// the index copy of each path `git diff` lists (tracked files only, so an
/// untracked file is never touched and `git clean` never runs); a staged
/// session restores HEAD's copy of the paths HEAD knows and removes the ones
/// staged as new, a rename being one of each.
pub(crate) async fn discard_all(
    state: &AppState,
    request: &WorktreeSessionRequest,
) -> Result<DiffResult, WriteFailure> {
    let _permit = permit(state)?;
    let target = authorize(
        state,
        &request.session_id,
        &request.capability_token,
        &request.source,
    )
    .await?;
    if !target.staged {
        let changed = listed_paths(
            &target.repo,
            &[
                "diff",
                "--name-only",
                "-z",
                "--no-renames",
                "--diff-filter=ACDMRT",
            ],
            &[],
            MAX_PATH_LISTING_BYTES,
        )
        .await?;
        let paths: Vec<String> = changed.into_iter().collect();
        run_over_paths(&target.repo, &["restore", "--worktree"], &paths).await?;
        return Ok(mutated(&request.source));
    }
    let listed = listing(
        &target.repo,
        &["diff", "--cached", "--name-status", "-z"],
        &[],
        MAX_PATH_LISTING_BYTES,
    )
    .await?;
    let (in_head, added) = partition_staged_entries(&parse_name_status_z(&listed));
    run_over_paths(
        &target.repo,
        &["restore", "--staged", "--worktree", "--source=HEAD"],
        &in_head,
    )
    .await?;
    run_over_paths(
        &target.repo,
        &["rm", "-f", "-q", "--ignore-unmatch"],
        &added,
    )
    .await
    .map_err(|failure| removal_failure(failure, !in_head.is_empty()))?;
    Ok(mutated(&request.source))
}

/// Stages every tracked change (`git add --update`); untracked files are
/// never added.
pub(crate) async fn stage_all(
    state: &AppState,
    request: &WorktreeSessionRequest,
) -> Result<DiffResult, WriteFailure> {
    let _permit = permit(state)?;
    let target = authorize(
        state,
        &request.session_id,
        &request.capability_token,
        &request.source,
    )
    .await?;
    stage_tracked_changes(&target.repo).await?;
    Ok(mutated(&request.source))
}

/// Moves every staged change back to the working tree. On an unborn branch
/// there is no HEAD to restore the index from, so the index is emptied
/// instead; the files stay in the working tree either way.
pub(crate) async fn unstage_all(
    state: &AppState,
    request: &WorktreeSessionRequest,
) -> Result<DiffResult, WriteFailure> {
    let _permit = permit(state)?;
    let target = authorize(
        state,
        &request.session_id,
        &request.capability_token,
        &request.source,
    )
    .await?;
    let arguments: &[&str] = if head_exists(&target.repo).await? {
        &["restore", "--staged", "--", "."]
    } else {
        &["rm", "-r", "-q", "--cached", "--ignore-unmatch", "--", "."]
    };
    run_mutating(&target.repo, arguments, None).await?;
    Ok(mutated(&request.source))
}

async fn stage_tracked_changes(repo: &Path) -> Result<(), WriteFailure> {
    run_mutating(repo, &["add", "--update"], None).await
}

/// Runs a mutating command and requires success. Any failure is reported
/// with `state_may_have_changed`: Git may have changed some paths before
/// exiting non-zero for another.
async fn run_mutating(
    repo: &Path,
    arguments: &[&str],
    stdin: Option<&[u8]>,
) -> Result<(), WriteFailure> {
    if git_status(repo, arguments, Access::Mutating, stdin)
        .await
        .is_ok_and(|status| status.success())
    {
        Ok(())
    } else {
        Err(WriteFailure::after_write(WriteError::Failed))
    }
}

/// The error for a failed removal of the paths staged as new: the generic
/// failure when nothing else ran, `PartialRevert` once HEAD's paths were
/// already restored (a half-reverted rename).
fn removal_failure(failure: WriteFailure, restored_any: bool) -> WriteFailure {
    if restored_any {
        WriteFailure::after_write(WriteError::PartialRevert)
    } else {
        failure
    }
}

async fn head_exists(repo: &Path) -> Result<bool, WriteError> {
    Ok(git_status(
        repo,
        &["rev-parse", "--verify", "--quiet", "HEAD"],
        Access::ReadOnly,
        None,
    )
    .await?
    .success())
}

/// One entry of `git diff --name-status -z`: the status letter and its
/// path(s) (two for a rename or copy: source, then destination).
#[derive(Debug, Eq, PartialEq)]
pub(crate) struct NameStatusEntry {
    pub(crate) status: u8,
    pub(crate) paths: Vec<String>,
}

/// Parses `--name-status -z` output: `<status>[score]\0<path>\0`, with a
/// second path for `R` and `C`. Anything malformed ends the parse.
pub(crate) fn parse_name_status_z(output: &[u8]) -> Vec<NameStatusEntry> {
    let mut fields = output
        .split(|byte| *byte == 0)
        .map(|field| String::from_utf8_lossy(field).into_owned());
    let mut entries = Vec::new();
    while let Some(status) = fields.next() {
        let Some(&letter) = status.as_bytes().first() else {
            break;
        };
        let Some(path) = fields.next().filter(|path| !path.is_empty()) else {
            break;
        };
        let mut paths = vec![path];
        if letter == b'R' || letter == b'C' {
            let Some(destination) = fields.next().filter(|path| !path.is_empty()) else {
                break;
            };
            paths.push(destination);
        }
        entries.push(NameStatusEntry {
            status: letter,
            paths,
        });
    }
    entries
}

/// Splits staged entries into paths HEAD knows (restored from HEAD) and
/// paths staged as new (removed). A rename or copy contributes its source
/// to the first and its destination to the second. Unmerged and unknown
/// entries are left alone.
pub(crate) fn partition_staged_entries(entries: &[NameStatusEntry]) -> (Vec<String>, Vec<String>) {
    let mut in_head = Vec::new();
    let mut added = Vec::new();
    for entry in entries {
        match (entry.status, entry.paths.as_slice()) {
            (b'A', [path]) => added.push(path.clone()),
            (b'M' | b'D' | b'T', [path]) => in_head.push(path.clone()),
            (b'R' | b'C', [source, destination]) => {
                in_head.push(source.clone());
                added.push(destination.clone());
            }
            _ => {}
        }
    }
    (in_head, added)
}

/// Runs a mutating command over `paths`, fed NUL-delimited on stdin as
/// literal pathspecs so a session with thousands of files never hits the
/// argument-length limit. Nothing runs for an empty list.
async fn run_over_paths(
    repo: &Path,
    arguments: &[&str],
    paths: &[String],
) -> Result<(), WriteFailure> {
    if paths.is_empty() {
        return Ok(());
    }
    let mut stdin = Vec::new();
    for path in paths {
        stdin.extend_from_slice(path.as_bytes());
        stdin.push(0);
    }
    let mut full = vec!["--literal-pathspecs"];
    full.extend_from_slice(arguments);
    full.extend_from_slice(&["--pathspec-from-file=-", "--pathspec-file-nul"]);
    run_mutating(repo, &full, Some(&stdin)).await
}

// MARK: Push and repository status

pub(crate) async fn push(
    state: &AppState,
    request: &WorktreePushRequest,
) -> Result<DiffResult, WriteFailure> {
    let _permit = permit(state)?;
    let target = authorize(
        state,
        &request.session_id,
        &request.capability_token,
        &request.source,
    )
    .await?;
    let push_target = resolve_push_target(&target.repo).await?;
    let result = run_push(
        &target.repo,
        &push_target,
        request.set_upstream,
        PUSH_TIMEOUT,
    )
    .await?;
    Ok(DiffResult::Pushed(result))
}

/// The branch a push or pull request acts on, resolved once: its upstream
/// and the remote a new upstream would go to.
struct PushTarget {
    branch: String,
    upstream: Option<Upstream>,
    push_remote: String,
}

impl PushTarget {
    /// The remote the branch is published on: its upstream's, or the push
    /// remote when it has none yet.
    fn remote(&self) -> &str {
        self.upstream
            .as_ref()
            .map_or(self.push_remote.as_str(), |upstream| {
                upstream.remote.as_str()
            })
    }
}

/// Resolves the checked-out branch (`DetachedHead` when there is none), its
/// upstream, and its push remote from one configuration read.
async fn resolve_push_target(repo: &Path) -> Result<PushTarget, WriteError> {
    let branch = current_branch(repo)
        .await?
        .ok_or(WriteError::DetachedHead)?;
    let config = branch_config(repo, &branch).await;
    let upstream = upstream(repo, &config).await;
    Ok(PushTarget {
        branch,
        upstream,
        push_remote: config.push_remote_name(),
    })
}

/// Pushes `target`'s branch the way a bare `git push` would, within
/// `timeout`. The push remote is resolved like Git's own (`pushRemote`,
/// `remote.pushDefault`, the branch's fetch remote, `origin`); when it is the
/// upstream's remote the branch lands under its upstream name, and in a
/// triangular workflow (a different push remote) it lands under its own name
/// there while the upstream stays untouched. Without an upstream,
/// `set_upstream` creates one on the push remote.
async fn run_push(
    repo: &Path,
    target: &PushTarget,
    set_upstream: bool,
    timeout: Duration,
) -> Result<PushResult, WriteError> {
    let branch = target.branch.clone();
    let push_remote = target.push_remote.clone();
    let (remote, refspec, upstream_created) = match &target.upstream {
        Some(upstream) if upstream.remote == push_remote => (
            upstream.remote.clone(),
            format!("{branch}:{}", upstream.merge_ref),
            false,
        ),
        Some(_) => (push_remote, format!("{branch}:refs/heads/{branch}"), false),
        None if set_upstream => {
            if git::single_line(repo, &["remote", "get-url", &push_remote])
                .await
                .is_err()
            {
                return Err(WriteError::PushRejected(Some(format!(
                    "remote '{push_remote}' is not configured"
                ))));
            }
            (push_remote, branch.clone(), true)
        }
        None => return Err(WriteError::NoUpstream),
    };
    let mut arguments = vec!["push"];
    if upstream_created {
        arguments.push("--set-upstream");
    }
    arguments.extend(["--", remote.as_str(), refspec.as_str()]);
    let (_, stderr, status) = git::capture_network(
        repo,
        &arguments,
        MAX_STATUS_OUTPUT_BYTES,
        MAX_HOOK_STDERR_BYTES,
        timeout,
    )
    .await
    .map_err(|()| WriteError::PushRejected(Some("timed out".to_owned())))?;
    if !status.success() {
        return Err(push_rejection(&stderr));
    }
    Ok(PushResult {
        remote,
        branch,
        upstream_created,
    })
}

/// Classifies a failed push: an authentication problem (missing credentials,
/// a forbidden prompt, a denied key) or a plain rejection with Git's last
/// word. A 403 is the latter: the user is known to the remote and lacks
/// write permission, which signing in again would not change.
fn push_rejection(stderr: &[u8]) -> WriteError {
    if mentions_authentication(&String::from_utf8_lossy(stderr)) {
        return WriteError::AuthRequired;
    }
    WriteError::PushRejected(last_stderr_line(stderr))
}

fn mentions_authentication(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    [
        "authentication failed",
        "authentication required",
        "could not read username",
        "could not read password",
        "terminal prompts disabled",
        "permission denied (publickey",
        "invalid username or password",
        "invalid credentials",
        "returned error: 401",
        "http 401",
        "not logged in",
        "auth login",
    ]
    .iter()
    .any(|needle| lower.contains(needle))
}

/// The checked-out branch, or `None` when HEAD is detached. An unborn branch
/// still has a name.
async fn current_branch(repo: &Path) -> Result<Option<String>, WriteError> {
    if let Ok(branch) =
        git::single_line(repo, &["symbolic-ref", "--quiet", "--short", "HEAD"]).await
    {
        return Ok(Some(branch));
    }
    if head_exists(repo).await? {
        Ok(None)
    } else {
        Err(WriteError::Failed)
    }
}

/// The configuration a push or status reads for one branch, from a single
/// `git config --get-regexp` child: the branch's fetch remote and merge ref,
/// its push remote, and the repository's push default. A key that is unset
/// (or empty) is `None`.
#[derive(Debug, Default, Eq, PartialEq)]
struct BranchConfig {
    remote: Option<String>,
    merge: Option<String>,
    push_remote: Option<String>,
    push_default: Option<String>,
}

impl BranchConfig {
    /// The upstream's remote and merge ref when both are configured for a
    /// real remote. The remote-tracking ref may still be missing locally
    /// (see [`upstream`]).
    fn configured_upstream(&self) -> Option<(&str, &str)> {
        let remote = self.remote.as_deref()?;
        let merge_ref = self.merge.as_deref()?;
        (remote != "." && merge_ref.starts_with("refs/heads/")).then_some((remote, merge_ref))
    }

    /// The remote a new upstream goes to: the branch's push remote, the
    /// repository's push default, the branch's fetch remote, then `origin`.
    fn push_remote_name(&self) -> String {
        [&self.push_remote, &self.push_default, &self.remote]
            .into_iter()
            .flatten()
            .find(|remote| remote.as_str() != ".")
            .cloned()
            .unwrap_or_else(|| "origin".to_owned())
    }
}

/// Reads `branch`'s [`BranchConfig`] with one `git config --get-regexp -z`.
/// Git canonicalizes section and variable names to lower case (the branch
/// name keeps its case) and separates each `key\nvalue` record with NUL; like
/// `--get`, the last value of a repeated key wins.
async fn branch_config(repo: &Path, branch: &str) -> BranchConfig {
    let pattern = format!(
        "^(branch\\.{}\\.(remote|merge|pushremote)|remote\\.pushdefault)$",
        regex_literal(branch)
    );
    let Ok((stdout, _)) = git::capture(
        repo,
        &["config", "--get-regexp", "-z", &pattern],
        Access::ReadOnly,
        None,
        MAX_STATUS_OUTPUT_BYTES,
    )
    .await
    else {
        return BranchConfig::default();
    };
    parse_branch_config(&stdout, branch)
}

/// Parses `git config --get-regexp -z` output for `branch` (see
/// [`branch_config`]). A value is taken the way `git::single_line` reads a
/// `--get` answer: trimmed, and dropped when empty or spanning lines.
fn parse_branch_config(output: &[u8], branch: &str) -> BranchConfig {
    let mut config = BranchConfig::default();
    for record in output.split(|byte| *byte == 0) {
        let Ok(record) = std::str::from_utf8(record) else {
            continue;
        };
        let Some((key, value)) = record.split_once('\n') else {
            continue;
        };
        let branch_key = key
            .strip_prefix("branch.")
            .and_then(|rest| rest.strip_prefix(branch))
            .and_then(|rest| rest.strip_prefix('.'));
        let slot = match branch_key {
            Some("remote") => &mut config.remote,
            Some("merge") => &mut config.merge,
            Some("pushremote") => &mut config.push_remote,
            None if key == "remote.pushdefault" => &mut config.push_default,
            _ => continue,
        };
        let value = value.trim();
        *slot = (!value.is_empty() && !value.contains(['\r', '\n'])).then(|| value.to_owned());
    }
    config
}

/// `text` as a POSIX extended regular expression matching only itself.
fn regex_literal(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len());
    for character in text.chars() {
        if r".[]{}()\*+?|^$".contains(character) {
            escaped.push('\\');
        }
        escaped.push(character);
    }
    escaped
}

struct Upstream {
    remote: String,
    /// `refs/heads/<name>` on the remote.
    merge_ref: String,
    /// `<remote>/<name>`, as `rev-parse --abbrev-ref` prints it.
    short: String,
}

/// The branch's configured, fetched upstream. Configuration alone is not
/// enough: an upstream whose remote-tracking ref is missing locally cannot
/// be pushed to by name, so it counts as absent and `-u` recreates it.
async fn upstream(repo: &Path, config: &BranchConfig) -> Option<Upstream> {
    let (remote, merge_ref) = config.configured_upstream()?;
    let short = git::single_line(
        repo,
        &[
            "rev-parse",
            "--abbrev-ref",
            "--symbolic-full-name",
            "@{upstream}",
        ],
    )
    .await
    .ok()?;
    Some(Upstream {
        remote: remote.to_owned(),
        merge_ref: merge_ref.to_owned(),
        short,
    })
}

/// `(behind, ahead)` of HEAD relative to its upstream.
async fn ahead_behind(repo: &Path) -> Option<(u32, u32)> {
    let counts = git::single_line(
        repo,
        &["rev-list", "--left-right", "--count", "@{upstream}...HEAD"],
    )
    .await
    .ok()?;
    let (behind, ahead) = counts.split_once(char::is_whitespace)?;
    Some((behind.trim().parse().ok()?, ahead.trim().parse().ok()?))
}

/// The forge `remote`'s URL points at (`None` when the remote is not
/// configured).
async fn remote_host_kind(repo: &Path, remote: &str) -> RepositoryHostKind {
    let url = git::single_line(repo, &["remote", "get-url", remote])
        .await
        .ok();
    forge::host_kind(url.as_deref())
}

pub(crate) async fn repository_status(
    state: &AppState,
    request: &WorktreeSessionRequest,
) -> Result<DiffResult, WriteFailure> {
    // The permit covers the local Git children only: the forge CLI waits on
    // the network for up to two `FORGE_CLI_TIMEOUT`s, and a permit held that
    // long would starve session opens and writes, which `try_acquire`.
    let local = {
        let _permit = permit(state)?;
        let target = authorize(
            state,
            &request.session_id,
            &request.capability_token,
            &request.source,
        )
        .await?;
        local_status(&target.repo).await?
    };
    Ok(DiffResult::RepositoryStatus(forge_status(local).await))
}

/// What local Git knows: branch, upstream, position, and the remote's forge,
/// plus that forge's CLI when installed (not yet consulted).
struct LocalStatus {
    branch: String,
    detached: bool,
    upstream: Option<Upstream>,
    ahead: u32,
    behind: u32,
    host_kind: RepositoryHostKind,
    cli: Option<ForgeCli>,
}

/// Gathers [`LocalStatus`]. After the branch and its configuration, the
/// children that depend only on those run concurrently: the upstream's
/// tracking ref, the ahead/behind count, and the remote's URL.
async fn local_status(repo: &Path) -> Result<LocalStatus, WriteError> {
    let (branch, detached) = match current_branch(repo).await? {
        Some(branch) => (branch, false),
        None => (
            git::single_line(repo, &["rev-parse", "--short", "HEAD"])
                .await
                .unwrap_or_else(|()| "HEAD".to_owned()),
            true,
        ),
    };
    if detached {
        let host_kind = remote_host_kind(repo, "origin").await;
        return Ok(LocalStatus {
            branch,
            detached,
            upstream: None,
            ahead: 0,
            behind: 0,
            host_kind,
            cli: locate_cli(host_kind, repo),
        });
    }
    let config = branch_config(repo, &branch).await;
    // The remote is the upstream's when its tracking ref exists, else the
    // push remote; both names come from the configuration, so the likely one
    // is looked up now and the other only when the ref turns out missing.
    // The count fails the same way as the ref lookup then and stays (0, 0).
    let configured = config.configured_upstream();
    let candidate = configured.map_or_else(
        || config.push_remote_name(),
        |(remote, _)| remote.to_owned(),
    );
    let (upstream, counts, candidate_host) = tokio::join!(
        upstream(repo, &config),
        async {
            if configured.is_some() {
                ahead_behind(repo).await
            } else {
                None
            }
        },
        remote_host_kind(repo, &candidate),
    );
    let remote = upstream.as_ref().map_or_else(
        || config.push_remote_name(),
        |upstream| upstream.remote.clone(),
    );
    let host_kind = if remote == candidate {
        candidate_host
    } else {
        remote_host_kind(repo, &remote).await
    };
    let (behind, ahead) = counts.unwrap_or((0, 0));
    Ok(LocalStatus {
        branch,
        detached,
        upstream,
        ahead,
        behind,
        host_kind,
        cli: locate_cli(host_kind, repo),
    })
}

fn locate_cli(host_kind: RepositoryHostKind, repo: &Path) -> Option<ForgeCli> {
    ForgeCliKind::for_host(host_kind).and_then(|kind| ForgeCli::locate(kind, repo))
}

/// Adds what the forge CLI knows: whether it is signed in, and the branch's
/// pull request. Each is one network round trip needing only the branch, so
/// they run concurrently; the request counts only for a signed-in CLI, as a
/// signed-out one has no answer to trust. No CLI still yields a status.
async fn forge_status(local: LocalStatus) -> RepositoryStatus {
    let LocalStatus {
        branch,
        detached,
        upstream,
        ahead,
        behind,
        host_kind,
        cli,
    } = local;
    let (authenticated, pull_request) = match &cli {
        Some(cli) => {
            let (authenticated, pull_request) =
                tokio::join!(cli.is_authenticated(FORGE_CLI_TIMEOUT), async {
                    if detached {
                        None
                    } else {
                        cli.pull_request(&branch, FORGE_CLI_TIMEOUT).await
                    }
                },);
            (authenticated, pull_request.filter(|_| authenticated))
        }
        None => (false, None),
    };
    RepositoryStatus {
        branch,
        detached,
        upstream: upstream.map(|upstream| upstream.short),
        ahead,
        behind,
        host_kind,
        forge_cli: ForgeCliStatus {
            available: cli.is_some(),
            authenticated,
        },
        pull_request,
    }
}

// MARK: Pull requests

pub(crate) async fn create_pull_request(
    state: &AppState,
    request: &WorktreeCreatePullRequestRequest,
) -> Result<DiffResult, WriteFailure> {
    let _permit = permit(state)?;
    let target = authorize(
        state,
        &request.session_id,
        &request.capability_token,
        &request.source,
    )
    .await?;
    let title = validate_pull_request_title(&request.title)?;
    let body = validate_pull_request_body(&request.body)?;
    let base = request.base.as_deref().map(validate_ref_name).transpose()?;
    // One deadline for the chained flow. Every child is killed on drop in its
    // own process group, so the step running when it passes dies with it.
    let created = tokio::time::timeout(
        PULL_REQUEST_FLOW_BUDGET,
        pull_request_flow(&target.repo, title, body, base, request.draft),
    )
    .await
    .map_err(|_| WriteError::PullRequestCreateFailed(Some("timed out".to_owned())))??;
    Ok(DiffResult::PullRequestCreated(created))
}

/// `auth status`, the implicit push of a branch without an upstream, the
/// lookup of an existing request, then `pr create` / `mr create`, each
/// within its own maximum and all under the caller's flow budget.
async fn pull_request_flow(
    repo: &Path,
    title: &str,
    body: &str,
    base: Option<&str>,
    draft: bool,
) -> Result<PullRequestCreated, WriteError> {
    let target = resolve_push_target(repo).await?;
    let host_kind = remote_host_kind(repo, target.remote()).await;
    let cli = locate_cli(host_kind, repo).ok_or(WriteError::ForgeCliMissing)?;
    if !cli.is_authenticated(FORGE_CLI_TIMEOUT).await {
        return Err(WriteError::ForgeNotAuthenticated);
    }
    // The forge only sees the branch once it has been pushed.
    if target.upstream.is_none() {
        run_push(repo, &target, true, PUSH_TIMEOUT).await?;
    }
    let branch = target.branch.as_str();
    if let Some(existing) = cli.pull_request(branch, FORGE_CLI_TIMEOUT).await
        && existing.state == "open"
    {
        return Err(WriteError::PullRequestExists(Some(existing.url)));
    }
    let (arguments, stdin) =
        pull_request_create_command(cli.kind, title, body, branch, draft, base);
    let borrowed: Vec<&str> = arguments.iter().map(String::as_str).collect();
    let output = cli
        .run(&borrowed, stdin.as_deref(), FORGE_CLI_TIMEOUT)
        .await
        .map_err(|()| WriteError::PullRequestCreateFailed(Some("timed out".to_owned())))?;
    let stdout = output.stdout_text();
    let stderr = output.stderr_text();
    if !output.status.success() {
        return Err(pull_request_create_failure(&stderr));
    }
    let url = forge::first_url(&stdout)
        .or_else(|| forge::first_url(&stderr))
        .ok_or(WriteError::PullRequestCreateFailed(None))?
        .to_owned();
    let number = match forge::number_from_url(&url) {
        Some(number) => number,
        None => cli
            .pull_request(branch, FORGE_CLI_TIMEOUT)
            .await
            .map_or(0, |summary| summary.number),
    };
    Ok(PullRequestCreated {
        number,
        url,
        title: title.to_owned(),
        is_draft: draft,
    })
}

/// The forge CLI invocation that creates the request. Every user value rides
/// in `--flag=value` form (never as a bare argument a parser could read as an
/// option), and `gh` takes the body on stdin so its size never touches the
/// argument list.
pub(crate) fn pull_request_create_command(
    kind: ForgeCliKind,
    title: &str,
    body: &str,
    branch: &str,
    draft: bool,
    base: Option<&str>,
) -> (Vec<String>, Option<Vec<u8>>) {
    let mut arguments: Vec<String> = match kind {
        ForgeCliKind::Gh => vec![
            "pr".to_owned(),
            "create".to_owned(),
            format!("--title={title}"),
            "--body-file=-".to_owned(),
            format!("--head={branch}"),
        ],
        ForgeCliKind::Glab => vec![
            "mr".to_owned(),
            "create".to_owned(),
            format!("--title={title}"),
            format!("--description={body}"),
            format!("--source-branch={branch}"),
            "--yes".to_owned(),
        ],
    };
    if draft {
        arguments.push("--draft".to_owned());
    }
    if let Some(base) = base {
        arguments.push(match kind {
            ForgeCliKind::Gh => format!("--base={base}"),
            ForgeCliKind::Glab => format!("--target-branch={base}"),
        });
    }
    let stdin = match kind {
        ForgeCliKind::Gh => Some(body.as_bytes().to_vec()),
        ForgeCliKind::Glab => None,
    };
    (arguments, stdin)
}

/// Classifies a failed `pr create`/`mr create`: the request already exists
/// (with its URL when the CLI printed one), the CLI lost its login, or a
/// plain failure carrying the CLI's last word.
fn pull_request_create_failure(stderr: &str) -> WriteError {
    if stderr.to_ascii_lowercase().contains("already exists") {
        return WriteError::PullRequestExists(forge::first_url(stderr).map(str::to_owned));
    }
    if mentions_authentication(stderr) {
        return WriteError::ForgeNotAuthenticated;
    }
    WriteError::PullRequestCreateFailed(last_stderr_line(stderr.as_bytes()))
}

/// A title is one non-empty line of at most 256 bytes.
pub(crate) fn validate_pull_request_title(raw: &str) -> Result<&str, WriteError> {
    let title = raw.trim();
    if title.is_empty()
        || title.len() > MAX_PULL_REQUEST_TITLE_BYTES
        || title.chars().any(char::is_control)
    {
        return Err(WriteError::InvalidTitle);
    }
    Ok(title)
}

/// A body is free text of at most 64 KiB without NUL bytes.
pub(crate) fn validate_pull_request_body(raw: &str) -> Result<&str, WriteError> {
    if raw.len() > MAX_PULL_REQUEST_BODY_BYTES || raw.contains('\0') {
        return Err(WriteError::InvalidBody);
    }
    Ok(raw)
}

/// A base branch is a short ref name: no whitespace or control characters,
/// no leading dash (never an option), no `..`, bounded.
pub(crate) fn validate_ref_name(raw: &str) -> Result<&str, WriteError> {
    let name = raw.trim();
    if name.is_empty()
        || name.len() > MAX_REF_NAME_BYTES
        || name.starts_with('-')
        || name.starts_with('/')
        || name.ends_with('/')
        || name.contains("..")
        || name.contains("@{")
        || name
            .chars()
            .any(|character| character.is_whitespace() || character.is_control())
        || name.contains(['~', '^', ':', '?', '*', '[', '\\'])
    {
        return Err(WriteError::InvalidBase);
    }
    Ok(name)
}

fn mutated(source: &DiffSource) -> DiffResult {
    DiffResult::WorktreeMutated(WorktreeMutated {
        source: source.clone(),
    })
}

fn permit(state: &AppState) -> Result<tokio::sync::SemaphorePermit<'_>, WriteError> {
    state
        .child_processes
        .try_acquire()
        .map_err(|_| WriteError::Failed)
}

/// Resolves the repository a write may touch. The token must be valid and
/// allowed for the repository; the session must be open, owned by the token,
/// and bound to the same canonical repository and source kind; and the
/// repository must be the top level of its working tree, since pathspecs and
/// `git apply` resolve against the current directory.
async fn authorize(
    state: &AppState,
    session_id: &str,
    token: &str,
    source: &DiffSource,
) -> Result<Target, WriteError> {
    if !valid_token(token) || uuid::Uuid::parse_str(session_id).is_err() {
        return Err(WriteError::NotAllowed);
    }
    let (repo_root, staged) = match source {
        DiffSource::Unstaged { repo_root } => (repo_root, false),
        DiffSource::Staged { repo_root } => (repo_root, true),
        DiffSource::Patch { .. } | DiffSource::Branch { .. } => {
            return Err(WriteError::NotAllowed);
        }
    };
    let repo = tokio::fs::canonicalize(repo_root)
        .await
        .map_err(|_| WriteError::NotAllowed)?;
    if !authorize_canonical_repo_for_token(state, token, &repo).await
        || !session_owned_by(state, session_id, token, &repo, source.kind()).await
        || !is_worktree_top_level(&repo).await
    {
        return Err(WriteError::NotAllowed);
    }
    Ok(Target { repo, staged })
}

/// Whether `repo` (canonical) is the top level of its working tree. Diff
/// paths are always top-level relative; a nested root would resolve literal
/// pathspecs against the wrong directory and make `git apply` skip paths.
async fn is_worktree_top_level(repo: &Path) -> bool {
    let Ok(top_level) = git::single_line(repo, &["rev-parse", "--show-toplevel"]).await else {
        return false;
    };
    tokio::fs::canonicalize(top_level)
        .await
        .is_ok_and(|top_level| top_level == repo)
}

async fn session_owned_by(
    state: &AppState,
    session_id: &str,
    token: &str,
    repo: &Path,
    kind: DiffSourceKind,
) -> bool {
    let Ok(Some(owner)) = read_session_owner(&state.config.root, session_id) else {
        return false;
    };
    if owner.capability_token != token
        || owner.repo_root.as_deref().map(Path::new) != Some(repo)
        || owner.source_kind != Some(kind)
    {
        return false;
    }
    // Closing a session removes its patch from the token's manifest, which
    // ends the write authority even while the owner descriptor lingers.
    let Some(files) = manifest_files(state, token).await else {
        return false;
    };
    files
        .get(&session_request_path(session_id))
        .is_some_and(|file| file.remote_url.is_none())
}

fn file_paths(request: &WorktreeFileRequest) -> Result<Vec<String>, WriteError> {
    let mut paths = vec![validate_repo_relative_path(&request.path)?.to_owned()];
    if let Some(previous) = &request.previous_path {
        let previous = validate_repo_relative_path(previous)?;
        if previous != request.path {
            paths.push(previous.to_owned());
        }
    }
    Ok(paths)
}

/// The paths of a selection action: each validated like a single-file path,
/// duplicates dropped (first occurrence kept), never empty, and bounded to
/// [`MAX_BATCH_PATHS`]. A refused path refuses the whole batch, before any
/// Git child runs.
pub(crate) fn batch_paths(paths: &[String]) -> Result<Vec<String>, WriteError> {
    if paths.is_empty() || paths.len() > MAX_BATCH_PATHS {
        return Err(WriteError::InvalidPath);
    }
    let mut seen = HashSet::with_capacity(paths.len());
    let mut validated = Vec::with_capacity(paths.len());
    for path in paths {
        let path = validate_repo_relative_path(path)?;
        if seen.insert(path) {
            validated.push(path.to_owned());
        }
    }
    Ok(validated)
}

/// Accepts only a normalized repository-relative path: no leading slash, no
/// empty, `.` or `..` components, no NUL bytes, and a bounded length. Every
/// Git invocation still passes paths after `--` as literal pathspecs.
pub(crate) fn validate_repo_relative_path(path: &str) -> Result<&str, WriteError> {
    if path.is_empty()
        || path.len() > MAX_REPO_RELATIVE_PATH_BYTES
        || path.contains('\0')
        || path.starts_with('/')
        || path.ends_with('/')
        || path
            .split('/')
            .any(|component| component.is_empty() || component == "." || component == "..")
    {
        return Err(WriteError::InvalidPath);
    }
    Ok(path)
}

fn literal_pathspec(path: &str) -> String {
    format!(":(literal){path}")
}

fn require_all(paths: &[String], known: &HashSet<String>) -> Result<(), WriteError> {
    if paths.iter().all(|path| known.contains(path)) {
        Ok(())
    } else {
        Err(WriteError::InvalidPath)
    }
}

/// Discards the changes to `paths`. An unstaged session restores the index
/// copy of index-tracked files; a staged session restores the HEAD copy of
/// files HEAD knows and removes files staged as new.
///
/// A path Git knows nothing about is refused. A `git diff` session never
/// lists untracked files, so such a path can only come from the page, and
/// honoring it (with `git clean`) would delete an arbitrary untracked file.
/// Listings match whole blobs only, so a directory name is never "known".
async fn revert_paths(target: &Target, paths: &[String]) -> Result<(), WriteFailure> {
    let in_index = index_paths(&target.repo, paths).await?;
    if !target.staged {
        require_all(paths, &in_index)?;
        return run_over_paths(&target.repo, &["restore", "--worktree"], paths).await;
    }
    let head = head_paths(&target.repo, paths).await?;
    let (in_head, added): (Vec<String>, Vec<String>) =
        paths.iter().cloned().partition(|path| head.contains(path));
    require_all(&added, &in_index)?;
    run_over_paths(
        &target.repo,
        &["restore", "--staged", "--worktree", "--source=HEAD"],
        &in_head,
    )
    .await?;
    // A file staged as new has no HEAD version to restore; discarding it
    // removes the index entry and the working-tree copy. Once the restore
    // above has run, a failure here leaves a half-reverted rename.
    run_over_paths(
        &target.repo,
        &["rm", "-f", "-q", "--ignore-unmatch"],
        &added,
    )
    .await
    .map_err(|failure| removal_failure(failure, !in_head.is_empty()))
}

/// The subset of `paths` that are index entries.
async fn index_paths(repo: &Path, paths: &[String]) -> Result<HashSet<String>, WriteError> {
    listed_paths(repo, &["ls-files", "-z"], paths, MAX_STATUS_OUTPUT_BYTES).await
}

/// The subset of `paths` that are blobs in HEAD's tree (`-r`, so a directory
/// lists its files and never itself). An unborn branch has no HEAD tree, so
/// nothing is in it.
async fn head_paths(repo: &Path, paths: &[String]) -> Result<HashSet<String>, WriteError> {
    match listed_paths(
        repo,
        &["ls-tree", "-r", "-z", "--name-only", "HEAD"],
        paths,
        MAX_STATUS_OUTPUT_BYTES,
    )
    .await
    {
        Ok(listed) => Ok(listed),
        Err(error) => {
            let head_exists = git_status(
                repo,
                &["rev-parse", "--verify", "--quiet", "HEAD"],
                Access::ReadOnly,
                None,
            )
            .await?
            .success();
            if head_exists {
                Err(error)
            } else {
                Ok(HashSet::new())
            }
        }
    }
}

/// The names a NUL-delimited listing (`ls-files -z`, `ls-tree -r -z`, `diff
/// --name-only -z`) prints for `paths` (see [`listing`]), or for the whole
/// session when `paths` is empty. A path that names a directory lists its
/// children, none of which equal the path itself, so it is never classified
/// as tracked. A selection's paths are listed in chunks (see
/// [`pathspec_chunks`]); each chunk's output is bounded by `limit`.
async fn listed_paths(
    repo: &Path,
    arguments: &[&str],
    paths: &[String],
    limit: usize,
) -> Result<HashSet<String>, WriteError> {
    let mut listed = HashSet::new();
    for chunk in pathspec_chunks(paths) {
        listed.extend(
            listing(repo, arguments, chunk, limit)
                .await?
                .split(|byte| *byte == 0)
                .filter(|name| !name.is_empty())
                .filter_map(|name| std::str::from_utf8(name).ok())
                .map(str::to_owned),
        );
    }
    Ok(listed)
}

/// Splits `paths` into command-line sized chunks: each holds at most
/// [`MAX_LISTING_PATHSPEC_BYTES`] of path text (one path at least, so a
/// maximum-length path still fits). An empty list yields one empty chunk,
/// which [`listing`] reads as "the whole session".
fn pathspec_chunks(paths: &[String]) -> Vec<&[String]> {
    if paths.is_empty() {
        return vec![paths];
    }
    let mut chunks = Vec::new();
    let mut start = 0;
    let mut bytes = 0;
    for (index, path) in paths.iter().enumerate() {
        if index > start && bytes + path.len() > MAX_LISTING_PATHSPEC_BYTES {
            chunks.push(&paths[start..index]);
            start = index;
            bytes = 0;
        }
        bytes += path.len();
    }
    chunks.push(&paths[start..]);
    chunks
}

/// A read-only listing over `paths` as literal pathspecs (the listing
/// commands take no `--pathspec-from-file`; callers chunk a long list), or
/// over the whole session when `paths` is empty, with at most `limit` bytes
/// of output.
async fn listing(
    repo: &Path,
    arguments: &[&str],
    paths: &[String],
    limit: usize,
) -> Result<Vec<u8>, WriteError> {
    let mut full: Vec<String> = arguments.iter().map(|value| (*value).to_owned()).collect();
    full.push("--".to_owned());
    full.extend(paths.iter().map(|path| literal_pathspec(path)));
    let borrowed: Vec<&str> = full.iter().map(String::as_str).collect();
    let (stdout, status) = git::capture(repo, &borrowed, Access::ReadOnly, None, limit)
        .await
        .map_err(|()| WriteError::Failed)?;
    if !status.success() {
        return Err(WriteError::Failed);
    }
    Ok(stdout)
}

/// Builds a single-hunk patch from the first file section of a unified diff:
/// that section's header (everything before its first `@@` line) followed by
/// the hunk whose header ranges equal `wanted`. The section must describe
/// `path`, and hunks end at the next `@@` or the next `diff --git ` line, so a
/// diff carrying a second file (a request whose `previous_path` names some
/// other modified file) can never lend that file's hunk to this one. Returns
/// `None` when no hunk matches.
pub(crate) fn select_hunk_patch(diff: &[u8], wanted: HunkRef, path: &str) -> Option<Vec<u8>> {
    let mut section_starts = Vec::new();
    let mut hunk_starts = Vec::new();
    let mut offset = 0;
    for line in diff.split_inclusive(|byte| *byte == b'\n') {
        if line.starts_with(b"diff --git ") {
            section_starts.push(offset);
        } else if line.starts_with(b"@@ ") {
            hunk_starts.push(offset);
        }
        offset += line.len();
    }
    let section_start = *section_starts.first()?;
    let section_end = section_starts.get(1).copied().unwrap_or(diff.len());
    let hunk_starts: Vec<usize> = hunk_starts
        .into_iter()
        .filter(|start| (section_start..section_end).contains(start))
        .collect();
    let raw_header = &diff[section_start..*hunk_starts.first()?];
    if !header_names_path(raw_header, path.as_bytes()) {
        return None;
    }
    let header = content_only_header(raw_header)?;
    for (index, start) in hunk_starts.iter().enumerate() {
        let end = hunk_starts.get(index + 1).copied().unwrap_or(section_end);
        let hunk = &diff[*start..end];
        let header_line = hunk.split(|byte| *byte == b'\n').next()?;
        if parse_hunk_header(header_line) == Some(wanted) {
            let mut selected = Vec::with_capacity(header.len() + hunk.len() + 1);
            selected.extend_from_slice(&header);
            selected.extend_from_slice(hunk);
            if !selected.ends_with(b"\n") {
                selected.push(b'\n');
            }
            return Some(selected);
        }
    }
    None
}

/// Whether a file section's header is about `path`: its `+++` side (the
/// `---` side for a deletion) names `path` under the pinned `b/` (`a/`)
/// prefix, after undoing Git's C-style quoting of unusual names.
fn header_names_path(header: &[u8], path: &[u8]) -> bool {
    let line = |prefix: &[u8]| {
        header
            .split(|byte| *byte == b'\n')
            .find_map(|line| line.strip_prefix(prefix))
    };
    let side = |marker: &[u8], prefix: &[u8]| -> Option<Vec<u8>> {
        let name = trim_name_line(line(marker)?);
        if name == b"/dev/null" {
            return None;
        }
        let unquoted = match name.first() {
            Some(b'"') => unquote_c_style(name)?,
            _ => name.to_vec(),
        };
        unquoted.strip_prefix(prefix).map(<[u8]>::to_vec)
    };
    match side(b"+++ ", b"b/") {
        Some(new_side) => new_side == path,
        None => side(b"--- ", b"a/").is_some_and(|old_side| old_side == path),
    }
}

/// A `---`/`+++` name as Git prints it: a name with spaces gets a trailing
/// tab so its end is unambiguous, and a CRLF diff a trailing CR.
fn trim_name_line(name: &[u8]) -> &[u8] {
    let name = name.strip_suffix(b"\r").unwrap_or(name);
    name.strip_suffix(b"\t").unwrap_or(name)
}

/// Undoes Git's C-style quoting (`"..."` with `\t`, `\"`, `\\` and octal
/// `\ooo` escapes, as `core.quotePath` produces). Anything malformed is
/// `None`.
fn unquote_c_style(quoted: &[u8]) -> Option<Vec<u8>> {
    let inner = quoted.strip_prefix(b"\"")?.strip_suffix(b"\"")?;
    let mut result = Vec::with_capacity(inner.len());
    let mut bytes = inner.iter().copied().peekable();
    while let Some(byte) = bytes.next() {
        if byte != b'\\' {
            result.push(byte);
            continue;
        }
        let escape = bytes.next()?;
        let value = match escape {
            b'a' => 0x07,
            b'b' => 0x08,
            b'f' => 0x0c,
            b'n' => b'\n',
            b'r' => b'\r',
            b't' => b'\t',
            b'v' => 0x0b,
            b'\\' => b'\\',
            b'"' => b'"',
            b'0'..=b'7' => {
                let mut value = u32::from(escape - b'0');
                for _ in 0..2 {
                    match bytes.peek() {
                        Some(digit @ b'0'..=b'7') => {
                            value = value * 8 + u32::from(*digit - b'0');
                            bytes.next();
                        }
                        _ => break,
                    }
                }
                u8::try_from(value).ok()?
            }
            _ => return None,
        };
        result.push(value);
    }
    Some(result)
}

/// Reverting one hunk only touches the file's content. A rename or copy
/// header would make `git apply -R` undo the rename as well, so such a header
/// is rewritten to name the new path on both sides; the `+++` line keeps
/// Git's own quoting. Other headers pass through unchanged.
fn content_only_header(header: &[u8]) -> Option<Cow<'_, [u8]>> {
    let mut lines = header.split_inclusive(|byte| *byte == b'\n');
    if !lines
        .clone()
        .any(|line| line.starts_with(b"rename from ") || line.starts_with(b"copy from "))
    {
        return Some(Cow::Borrowed(header));
    }
    let new_side = lines
        .find(|line| line.starts_with(b"+++ b/") || line.starts_with(b"+++ \"b/"))?
        .strip_prefix(b"+++ ")?;
    let new_side = trim_name_line(new_side.strip_suffix(b"\n").unwrap_or(new_side));
    let old_side: Vec<u8> = if let Some(rest) = new_side.strip_prefix(b"\"b/") {
        [b"\"a/".as_slice(), rest].concat()
    } else {
        [b"a/".as_slice(), new_side.strip_prefix(b"b/")?].concat()
    };
    let mut rewritten = Vec::with_capacity(header.len());
    rewritten.extend_from_slice(b"diff --git ");
    rewritten.extend_from_slice(&old_side);
    rewritten.push(b' ');
    rewritten.extend_from_slice(new_side);
    rewritten.extend_from_slice(b"\n--- ");
    rewritten.extend_from_slice(&old_side);
    rewritten.extend_from_slice(b"\n+++ ");
    rewritten.extend_from_slice(new_side);
    rewritten.push(b'\n');
    Some(Cow::Owned(rewritten))
}

/// Parses `@@ -old[,count] +new[,count] @@ ...` into its ranges. A missing
/// count means one line, as in unified diff.
pub(crate) fn parse_hunk_header(line: &[u8]) -> Option<HunkRef> {
    let text = std::str::from_utf8(line).ok()?;
    let rest = text.strip_prefix("@@ -")?;
    let (old, rest) = rest.split_once(" +")?;
    let (new, _) = rest.split_once(" @@")?;
    let (old_start, old_count) = parse_range(old)?;
    let (new_start, new_count) = parse_range(new)?;
    Some(HunkRef {
        old_start,
        old_count,
        new_start,
        new_count,
    })
}

fn parse_range(value: &str) -> Option<(u32, u32)> {
    match value.split_once(',') {
        Some((start, count)) => Some((start.parse().ok()?, count.parse().ok()?)),
        None => Some((value.parse().ok()?, 1)),
    }
}

/// Feeds a sidecar-built patch to `git apply` and reports whether it applied.
/// Only a failure to run Git at all is an error; a rejected patch is `false`.
async fn apply_patch(repo: &Path, arguments: &[&str], patch: &[u8]) -> Result<bool, WriteError> {
    git_status(repo, arguments, Access::Mutating, Some(patch))
        .await
        .map(|status| status.success())
}

async fn git_status(
    repo: &Path,
    arguments: &[&str],
    access: Access,
    stdin: Option<&[u8]>,
) -> Result<ExitStatus, WriteError> {
    git::capture(repo, arguments, access, stdin, MAX_STATUS_OUTPUT_BYTES)
        .await
        .map(|(_, status)| status)
        .map_err(|()| WriteError::Failed)
}

#[cfg(test)]
mod tests {
    use super::{
        BranchConfig, ForgeCliKind, HunkRef, MAX_BATCH_PATHS, MAX_LISTING_PATHSPEC_BYTES,
        NameStatusEntry, WriteError, WriteFailure, batch_paths, commit_rejection,
        header_names_path, mentions_authentication, parse_branch_config, parse_hunk_header,
        parse_name_status_z, partition_staged_entries, pathspec_chunks,
        pull_request_create_command, pull_request_create_failure, push_rejection, regex_literal,
        select_hunk_patch, unquote_c_style, validate_pull_request_body,
        validate_pull_request_title, validate_ref_name, validate_repo_relative_path,
    };

    #[test]
    fn batch_paths_validate_every_path_dedupe_and_refuse_an_empty_list() {
        let owned = |paths: &[&str]| -> Vec<String> {
            paths.iter().map(|path| (*path).to_owned()).collect()
        };
        assert_eq!(
            batch_paths(&owned(&["src/a.txt", "b.txt", "src/a.txt", "-dash.txt"])),
            Ok(owned(&["src/a.txt", "b.txt", "-dash.txt"]))
        );
        assert_eq!(batch_paths(&[]), Err(WriteError::InvalidPath));
        // One bad path refuses the batch, however many good ones surround it.
        for rejected in ["", "/etc/passwd", "../outside", "src/", "nul\0byte"] {
            assert_eq!(
                batch_paths(&owned(&["src/a.txt", rejected, "b.txt"])),
                Err(WriteError::InvalidPath),
                "{rejected:?}"
            );
        }
        let too_many: Vec<String> = (0..=MAX_BATCH_PATHS).map(|i| format!("f{i}.txt")).collect();
        assert_eq!(batch_paths(&too_many), Err(WriteError::InvalidPath));
        assert_eq!(
            batch_paths(&too_many[..MAX_BATCH_PATHS]).map(|paths| paths.len()),
            Ok(MAX_BATCH_PATHS)
        );
    }

    #[test]
    fn pathspec_chunks_stay_under_the_byte_budget_and_keep_order() {
        let empty: Vec<String> = Vec::new();
        assert_eq!(pathspec_chunks(&empty), vec![&empty[..]]);
        let long = "x".repeat(MAX_LISTING_PATHSPEC_BYTES / 2 + 1);
        let paths = vec![long.clone(), long.clone(), "short.txt".to_owned(), long];
        let chunks = pathspec_chunks(&paths);
        // Two halves never share a chunk; the short path rides with the third.
        assert_eq!(
            chunks.len(),
            3,
            "{:?}",
            chunks.iter().map(|c| c.len()).collect::<Vec<_>>()
        );
        assert_eq!(chunks[0].len(), 1);
        assert_eq!(chunks[1].len(), 2);
        assert_eq!(chunks[1][1], "short.txt");
        assert_eq!(chunks[2].len(), 1);
        let rejoined: Vec<&String> = chunks.iter().flat_map(|chunk| chunk.iter()).collect();
        assert_eq!(rejoined, paths.iter().collect::<Vec<_>>());
        for chunk in &chunks {
            assert!(
                chunk.len() == 1
                    || chunk.iter().map(String::len).sum::<usize>() <= MAX_LISTING_PATHSPEC_BYTES
            );
        }
    }

    #[test]
    fn write_failures_flag_a_diff_that_changed_under_the_page() {
        for changed in [
            WriteError::StaleHunk,
            WriteError::Conflict,
            WriteError::PartialRevert,
        ] {
            assert!(WriteFailure::from(changed).state_may_have_changed);
        }
        for current in [
            WriteError::NotAllowed,
            WriteError::Failed,
            WriteError::CommitFailed,
            WriteError::NothingToCommit,
        ] {
            assert!(!WriteFailure::from(current.clone()).state_may_have_changed);
            assert!(WriteFailure::after_write(current).state_may_have_changed);
        }
    }

    #[test]
    fn branch_config_reads_one_get_regexp_listing_and_resolves_the_push_remote() {
        let branch = "feat/x.y+1";
        assert_eq!(regex_literal(branch), "feat/x\\.y\\+1");
        assert_eq!(regex_literal("a(b)|c$"), "a\\(b\\)\\|c\\$");
        // Canonical keys: lower-case variable names, the branch as written,
        // `key\nvalue\0` records; a repeated key keeps its last value and an
        // empty one counts as unset.
        let output = b"branch.feat/x.y+1.remote\norigin\0branch.feat/x.y+1.merge\nrefs/heads/main\0branch.feat/x.y+1.pushremote\nfork\0remote.pushdefault\nteam\0branch.feat/x.y+1.remote\nupstream\0branch.other.remote\nnope\0branch.feat/x.y+1.pushremote\n\0";
        let config = parse_branch_config(output, branch);
        assert_eq!(
            config,
            BranchConfig {
                remote: Some("upstream".to_owned()),
                merge: Some("refs/heads/main".to_owned()),
                push_remote: None,
                push_default: Some("team".to_owned()),
            }
        );
        assert_eq!(
            config.configured_upstream(),
            Some(("upstream", "refs/heads/main"))
        );
        assert_eq!(config.push_remote_name(), "team");
        assert_eq!(parse_branch_config(b"", branch), BranchConfig::default());
        assert_eq!(BranchConfig::default().push_remote_name(), "origin");
        let local = BranchConfig {
            remote: Some(".".to_owned()),
            merge: Some("refs/heads/main".to_owned()),
            push_remote: None,
            push_default: None,
        };
        assert_eq!(local.configured_upstream(), None);
        assert_eq!(local.push_remote_name(), "origin");
        let triangular = BranchConfig {
            remote: Some("origin".to_owned()),
            merge: Some("refs/heads/main".to_owned()),
            push_remote: Some("fork".to_owned()),
            push_default: None,
        };
        assert_eq!(triangular.push_remote_name(), "fork");
    }

    #[test]
    fn name_status_listings_parse_renames_and_partition_by_head_membership() {
        let output = b"M\0story.txt\0A\0new.txt\0R087\0old.txt\0renamed.txt\0D\0gone.txt\0U\0conflict.txt\0T\0link\0";
        let entries = parse_name_status_z(output);
        assert_eq!(
            entries[2],
            NameStatusEntry {
                status: b'R',
                paths: vec!["old.txt".to_owned(), "renamed.txt".to_owned()],
            }
        );
        assert_eq!(entries.len(), 6);
        let (in_head, added) = partition_staged_entries(&entries);
        assert_eq!(in_head, ["story.txt", "old.txt", "gone.txt", "link"]);
        assert_eq!(added, ["new.txt", "renamed.txt"]);
        // A truncated record ends the parse instead of inventing a path.
        assert_eq!(
            parse_name_status_z(b"M\0story.txt\0R100\0old.txt\0").len(),
            1
        );
        assert!(parse_name_status_z(b"").is_empty());
    }

    #[test]
    fn push_failures_split_authentication_from_rejection() {
        assert_eq!(
            push_rejection(b"fatal: could not read Username for 'https://github.com': terminal prompts disabled\n"),
            WriteError::AuthRequired
        );
        assert_eq!(
            push_rejection(b"git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.\n"),
            WriteError::AuthRequired
        );
        let rejected = push_rejection(
            b"To /tmp/origin.git\n ! [rejected]        main -> main (fetch first)\nerror: failed to push some refs to '/tmp/origin.git'\nhint: Updates were rejected\x1b[0m\n",
        );
        assert_eq!(
            rejected,
            WriteError::PushRejected(Some("hint: Updates were rejected[0m".to_owned()))
        );
        assert_eq!(rejected.code(), "pushRejected");
        assert_eq!(push_rejection(b""), WriteError::PushRejected(None));
        // Progress output ends lines with CR; the last real line still wins.
        assert_eq!(
            push_rejection(b"Writing objects:  50%\rWriting objects: 100%\rerror: hook declined\n"),
            WriteError::PushRejected(Some("error: hook declined".to_owned()))
        );
        assert!(mentions_authentication("HTTP 401: Bad credentials"));
        assert!(!mentions_authentication("non-fast-forward"));
        // A 403 is a permission problem for a known user, not a missing login.
        let forbidden = push_rejection(
            b"remote: Permission to acme/widgets.git denied to dev.\nfatal: unable to access 'https://github.com/acme/widgets.git/': The requested URL returned error: 403\n",
        );
        assert_eq!(
            forbidden,
            WriteError::PushRejected(Some(
                "fatal: unable to access 'https://github.com/acme/widgets.git/': The requested URL returned error: 403".to_owned()
            ))
        );
        assert!(!mentions_authentication("HTTP 403: Forbidden"));
    }

    #[test]
    fn pull_request_create_commands_keep_values_in_flag_form() {
        let (gh, gh_stdin) = pull_request_create_command(
            ForgeCliKind::Gh,
            "-Title",
            "body\n--evil",
            "feat/x",
            true,
            Some("main"),
        );
        assert_eq!(
            gh,
            [
                "pr",
                "create",
                "--title=-Title",
                "--body-file=-",
                "--head=feat/x",
                "--draft",
                "--base=main"
            ]
        );
        assert_eq!(gh_stdin.as_deref(), Some(b"body\n--evil".as_slice()));
        let (glab, glab_stdin) =
            pull_request_create_command(ForgeCliKind::Glab, "T", "desc", "feat", false, None);
        assert_eq!(
            glab,
            [
                "mr",
                "create",
                "--title=T",
                "--description=desc",
                "--source-branch=feat",
                "--yes"
            ]
        );
        assert_eq!(glab_stdin, None);
        assert_eq!(
            pull_request_create_failure(
                "a pull request for branch \"feat\" into branch \"main\" already exists:\nhttps://github.com/acme/widgets/pull/7\n"
            ),
            WriteError::PullRequestExists(Some(
                "https://github.com/acme/widgets/pull/7".to_owned()
            ))
        );
        assert_eq!(
            pull_request_create_failure(
                "To get started with GitHub CLI, please run:  gh auth login\n"
            ),
            WriteError::ForgeNotAuthenticated
        );
        assert_eq!(
            pull_request_create_failure("GraphQL: Head sha can't be blank (createPullRequest)\n"),
            WriteError::PullRequestCreateFailed(Some(
                "GraphQL: Head sha can't be blank (createPullRequest)".to_owned()
            ))
        );
    }

    #[test]
    fn pull_request_inputs_are_bounded_and_option_safe() {
        assert_eq!(
            validate_pull_request_title("  Add widgets  "),
            Ok("Add widgets")
        );
        assert_eq!(
            validate_pull_request_title(""),
            Err(WriteError::InvalidTitle)
        );
        assert_eq!(
            validate_pull_request_title("a\nb"),
            Err(WriteError::InvalidTitle)
        );
        assert_eq!(
            validate_pull_request_title(&"x".repeat(257)),
            Err(WriteError::InvalidTitle)
        );
        let accented = "é".repeat(128);
        assert_eq!(
            validate_pull_request_title(&accented),
            Ok(accented.as_str())
        );
        assert!(validate_pull_request_body(&"b".repeat(64 * 1024)).is_ok());
        assert_eq!(
            validate_pull_request_body(&"b".repeat(64 * 1024 + 1)),
            Err(WriteError::InvalidBody)
        );
        assert_eq!(
            validate_pull_request_body("nul\0"),
            Err(WriteError::InvalidBody)
        );
        assert_eq!(validate_ref_name("main"), Ok("main"));
        assert_eq!(validate_ref_name("release/1.2"), Ok("release/1.2"));
        for rejected in [
            "", "-x", "--force", "a b", "a..b", "a@{1}", "a:b", "/x", "x/", "a?b",
        ] {
            assert_eq!(
                validate_ref_name(rejected),
                Err(WriteError::InvalidBase),
                "{rejected:?}"
            );
        }
        assert_eq!(
            WriteError::PullRequestExists(Some("https://x/pull/1".to_owned())).message(),
            "A pull request already exists for this branch: https://x/pull/1"
        );
        assert_eq!(WriteError::ForgeCliMissing.code(), "forgeCliMissing");
    }

    #[test]
    fn repo_relative_paths_reject_traversal_and_absolute_forms() {
        assert_eq!(
            validate_repo_relative_path("src/main.rs"),
            Ok("src/main.rs")
        );
        assert_eq!(
            validate_repo_relative_path("weird name.txt"),
            Ok("weird name.txt")
        );
        assert_eq!(validate_repo_relative_path("-dash.txt"), Ok("-dash.txt"));
        for rejected in [
            "",
            "/etc/passwd",
            "../outside",
            "src/../../outside",
            "src/./main.rs",
            "src//main.rs",
            "trailing/",
            "nul\0byte",
        ] {
            assert_eq!(
                validate_repo_relative_path(rejected),
                Err(WriteError::InvalidPath),
                "{rejected:?}"
            );
        }
    }

    #[test]
    fn hunk_headers_parse_with_and_without_counts() {
        assert_eq!(
            parse_hunk_header(b"@@ -1,3 +1,4 @@ fn main() {"),
            Some(HunkRef {
                old_start: 1,
                old_count: 3,
                new_start: 1,
                new_count: 4
            })
        );
        assert_eq!(
            parse_hunk_header(b"@@ -0,0 +1 @@"),
            Some(HunkRef {
                old_start: 0,
                old_count: 0,
                new_start: 1,
                new_count: 1
            })
        );
        assert_eq!(parse_hunk_header(b"diff --git a/x b/x"), None);
    }

    #[test]
    fn selected_hunk_patch_keeps_file_header_and_only_the_matching_hunk() {
        let diff = b"diff --git a/story.txt b/story.txt\nindex 1..2 100644\n--- a/story.txt\n+++ b/story.txt\n@@ -1,2 +1,3 @@\n one\n+two\n three\n@@ -10,2 +11,3 @@\n ten\n+eleven\n twelve\n";
        let second = HunkRef {
            old_start: 10,
            old_count: 2,
            new_start: 11,
            new_count: 3,
        };
        let patch = select_hunk_patch(diff, second, "story.txt").expect("second hunk");
        let text = String::from_utf8(patch).expect("utf8 patch");
        assert!(text.starts_with("diff --git a/story.txt b/story.txt\n"));
        assert!(text.contains("@@ -10,2 +11,3 @@\n ten\n+eleven\n twelve\n"));
        assert!(!text.contains("+two"));
        let stale = HunkRef {
            old_start: 10,
            old_count: 3,
            new_start: 11,
            new_count: 3,
        };
        assert!(select_hunk_patch(diff, stale, "story.txt").is_none());
        assert!(select_hunk_patch(b"", second, "story.txt").is_none());
        // The section must be about the requested path.
        assert!(select_hunk_patch(diff, second, "other.txt").is_none());
    }

    #[test]
    fn selected_hunk_patch_never_crosses_into_a_second_file_section() {
        let diff = b"diff --git a/a.txt b/a.txt\nindex 1..2 100644\n--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,3 @@\n one\n+two\n three\ndiff --git a/b.txt b/b.txt\nindex 3..4 100644\n--- a/b.txt\n+++ b/b.txt\n@@ -1,2 +1,3 @@\n uno\n+dos\n tres\n@@ -10,2 +11,3 @@\n diez\n+once\n doce\n";
        let first = HunkRef {
            old_start: 1,
            old_count: 2,
            new_start: 1,
            new_count: 3,
        };
        // The first section's hunk ends where the second section begins.
        let patch = select_hunk_patch(diff, first, "a.txt").expect("first section hunk");
        assert_eq!(
            String::from_utf8(patch).expect("utf8 patch"),
            "diff --git a/a.txt b/a.txt\nindex 1..2 100644\n--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,3 @@\n one\n+two\n three\n"
        );
        // A hunk that exists only in the second file is not found for the
        // first, and the first section's header is never lent to b.txt.
        let second_only = HunkRef {
            old_start: 10,
            old_count: 2,
            new_start: 11,
            new_count: 3,
        };
        assert!(select_hunk_patch(diff, second_only, "a.txt").is_none());
        assert!(select_hunk_patch(diff, second_only, "b.txt").is_none());
        assert!(select_hunk_patch(diff, first, "b.txt").is_none());
        // A first section without hunks (mode change) yields nothing, even
        // when the second section has a matching hunk.
        let mode_only = b"diff --git a/a.txt b/a.txt\nold mode 100644\nnew mode 100755\ndiff --git a/b.txt b/b.txt\n--- a/b.txt\n+++ b/b.txt\n@@ -1,2 +1,3 @@\n uno\n+dos\n tres\n";
        assert!(select_hunk_patch(mode_only, first, "a.txt").is_none());
        assert!(select_hunk_patch(mode_only, first, "b.txt").is_none());
    }

    #[test]
    fn selected_hunk_patch_rewrites_a_rename_header_onto_the_new_path() {
        let hunk = HunkRef {
            old_start: 8,
            old_count: 3,
            new_start: 8,
            new_count: 3,
        };
        let diff = b"diff --git a/old.txt b/new.txt\nsimilarity index 58%\nrename from old.txt\nrename to new.txt\nindex 1b2a1c5..aa939c4 100644\n--- a/old.txt\n+++ b/new.txt\n@@ -1,3 +1,3 @@\n l1\n-l2\n+l2 changed\n@@ -8,3 +8,3 @@\n l8\n-l9\n+l9 changed\n";
        let patch = select_hunk_patch(diff, hunk, "new.txt").expect("rename hunk");
        assert_eq!(
            String::from_utf8(patch).expect("utf8 patch"),
            "diff --git a/new.txt b/new.txt\n--- a/new.txt\n+++ b/new.txt\n@@ -8,3 +8,3 @@\n l8\n-l9\n+l9 changed\n"
        );
        assert!(select_hunk_patch(diff, hunk, "old.txt").is_none());
        let quoted = b"diff --git \"a/old\\ttab.txt\" \"b/new\\ttab.txt\"\nrename from \"old\\ttab.txt\"\nrename to \"new\\ttab.txt\"\n--- \"a/old\\ttab.txt\"\n+++ \"b/new\\ttab.txt\"\n@@ -8,3 +8,3 @@\n l8\n-l9\n+l9 changed\n";
        let patch = select_hunk_patch(quoted, hunk, "new\ttab.txt").expect("quoted rename hunk");
        assert!(
            String::from_utf8(patch)
                .expect("utf8 patch")
                .starts_with("diff --git \"a/new\\ttab.txt\" \"b/new\\ttab.txt\"\n--- \"a/new\\ttab.txt\"\n+++ \"b/new\\ttab.txt\"\n@@ -8,3 +8,3 @@\n")
        );
    }

    #[test]
    fn rename_header_rewrite_drops_the_trailing_name_tab() {
        let hunk = HunkRef {
            old_start: 1,
            old_count: 1,
            new_start: 1,
            new_count: 1,
        };
        let diff = b"diff --git \"a/old sp.txt\" \"b/new sp.txt\"\nrename from \"old sp.txt\"\nrename to \"new sp.txt\"\n--- \"a/old sp.txt\"\t\n+++ \"b/new sp.txt\"\t\n@@ -1 +1 @@\n-a\n+b\n";
        let patch = select_hunk_patch(diff, hunk, "new sp.txt").expect("rename hunk");
        assert_eq!(
            String::from_utf8(patch).expect("utf8 patch"),
            "diff --git \"a/new sp.txt\" \"b/new sp.txt\"\n--- \"a/new sp.txt\"\n+++ \"b/new sp.txt\"\n@@ -1 +1 @@\n-a\n+b\n"
        );
    }

    #[test]
    fn section_headers_match_quoted_deleted_and_added_paths() {
        assert!(header_names_path(
            b"diff --git a/x.txt b/x.txt\n--- a/x.txt\n+++ b/x.txt\n",
            b"x.txt"
        ));
        assert!(header_names_path(
            b"diff --git a/x.txt b/x.txt\ndeleted file mode 100644\n--- a/x.txt\n+++ /dev/null\n",
            b"x.txt"
        ));
        assert!(header_names_path(
            b"diff --git a/x.txt b/x.txt\nnew file mode 100644\n--- /dev/null\n+++ b/x.txt\n",
            b"x.txt"
        ));
        assert!(header_names_path(
            b"diff --git \"a/we\\\"ird\\ttab \\303\\251.txt\" \"b/we\\\"ird\\ttab \\303\\251.txt\"\n--- \"a/we\\\"ird\\ttab \\303\\251.txt\"\n+++ \"b/we\\\"ird\\ttab \\303\\251.txt\"\n",
            "we\"ird\ttab é.txt".as_bytes()
        ));
        // A name with spaces carries Git's trailing tab.
        assert!(header_names_path(
            b"diff --git \"a/sp ace.txt\" \"b/sp ace.txt\"\n--- \"a/sp ace.txt\"\t\n+++ \"b/sp ace.txt\"\t\n",
            b"sp ace.txt"
        ));
        assert!(header_names_path(
            b"diff --git a/x.txt b/x.txt\r\n--- a/x.txt\r\n+++ b/x.txt\r\n",
            b"x.txt"
        ));
        assert!(!header_names_path(
            b"diff --git a/x.txt b/x.txt\n--- a/x.txt\n+++ b/x.txt\n",
            b"y.txt"
        ));
        assert!(!header_names_path(
            b"diff --git a/x.txt b/x.txt\n",
            b"x.txt"
        ));
        assert_eq!(
            unquote_c_style(b"\"a\\tb\\\\c\\\"d\\303\\251\\0\""),
            Some(b"a\tb\\c\"d\xc3\xa9\0".to_vec())
        );
        assert_eq!(unquote_c_style(b"\"unterminated"), None);
        assert_eq!(unquote_c_style(b"\"bad\\q\""), None);
    }

    #[test]
    fn commit_rejections_surface_the_last_bounded_hook_line() {
        assert_eq!(commit_rejection(b""), WriteError::CommitFailed);
        assert_eq!(commit_rejection(b"\n  \n"), WriteError::CommitFailed);
        assert_eq!(
            commit_rejection(b"checking...\nhook says no\n\n"),
            WriteError::CommitRejected("hook says no".to_owned())
        );
        let long = format!("prefix\n{}\n", "x".repeat(1000));
        let WriteError::CommitRejected(detail) = commit_rejection(long.as_bytes()) else {
            panic!("expected a rejection");
        };
        assert_eq!(detail.len(), 200);
        assert_eq!(
            commit_rejection(b"bad \x1b[31mred\x1b[0m\x07"),
            WriteError::CommitRejected("bad [31mred[0m".to_owned())
        );
        let rejected = WriteError::CommitRejected("no".to_owned());
        assert_eq!(rejected.code(), "commitFailed");
        assert_eq!(rejected.message(), "Git could not create the commit: no");
    }
}
