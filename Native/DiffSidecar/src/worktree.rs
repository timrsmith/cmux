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

use crate::git::{self, Access};
use crate::manifest::valid_token;
use crate::protocol::{
    CommitResult, DiffResult, DiffSource, DiffSourceKind, HunkRef, WorktreeCommitRequest,
    WorktreeFileRequest, WorktreeHunkRequest, WorktreeMutated,
};
use crate::server::{
    AppState, authorize_canonical_repo_for_token, manifest_files, read_session_owner,
    session_request_path,
};

pub(crate) const MAX_COMMIT_MESSAGE_BYTES: usize = 64 * 1024;
const MAX_REPO_RELATIVE_PATH_BYTES: usize = 4096;
// One file's unified diff is re-read to select a hunk; anything larger is
// not something a per-hunk action should be reverting.
const MAX_HUNK_DIFF_BYTES: usize = 32 * 1024 * 1024;
// Path listings and status-style output (`ls-files`, `rev-parse`) for a
// handful of paths; reaching this means Git is not answering the question.
const MAX_STATUS_OUTPUT_BYTES: usize = 1024 * 1024;
// Hook output kept from a failed commit, and the slice of it surfaced.
const MAX_HOOK_STDERR_BYTES: usize = 16 * 1024;
const MAX_HOOK_DETAIL_CHARS: usize = 200;

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
            Self::Failed => "Could not update the working tree".into(),
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
) -> Result<DiffResult, WriteError> {
    file_op(state, request, FileOp::Revert).await
}

pub(crate) async fn stage_file(
    state: &AppState,
    request: &WorktreeFileRequest,
) -> Result<DiffResult, WriteError> {
    file_op(state, request, FileOp::Stage).await
}

pub(crate) async fn unstage_file(
    state: &AppState,
    request: &WorktreeFileRequest,
) -> Result<DiffResult, WriteError> {
    file_op(state, request, FileOp::Unstage).await
}

async fn file_op(
    state: &AppState,
    request: &WorktreeFileRequest,
    op: FileOp,
) -> Result<DiffResult, WriteError> {
    let _permit = permit(state)?;
    let target = authorize(
        state,
        &request.session_id,
        &request.capability_token,
        &request.source,
    )
    .await?;
    let paths = file_paths(request)?;
    match op {
        FileOp::Stage => {
            // A `git diff` session lists index-tracked files only, so a path
            // outside the index can only come from the page; staging it
            // would add an arbitrary untracked file.
            let in_index = listed_paths(&target.repo, &["ls-files", "-z"], &paths).await?;
            require_all(&paths, &in_index)?;
            run_checked(&target.repo, &["add"], &paths).await?;
        }
        FileOp::Unstage => {
            // A staged deletion has no index entry but is in HEAD, which is
            // where `restore --staged` takes it from.
            let mut known = listed_paths(&target.repo, &["ls-files", "-z"], &paths).await?;
            known.extend(head_paths(&target.repo, &paths).await?);
            require_all(&paths, &known)?;
            run_checked(&target.repo, &["restore", "--staged"], &paths).await?;
        }
        FileOp::Revert => revert_paths(&target, &paths).await?,
    }
    Ok(mutated(&request.source))
}

pub(crate) async fn revert_hunk(
    state: &AppState,
    request: &WorktreeHunkRequest,
) -> Result<DiffResult, WriteError> {
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
        return Err(WriteError::Failed);
    }
    let reverse_patch =
        select_hunk_patch(&diff, request.hunk, path).ok_or(WriteError::StaleHunk)?;
    let apply = ["apply", "-R", "--whitespace=nowarn"];
    if !target.staged {
        return if apply_patch(&target.repo, &apply, &reverse_patch).await? {
            Ok(mutated(&request.source))
        } else {
            Err(WriteError::Conflict)
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
        return Err(WriteError::Conflict);
    }
    if apply_patch(&target.repo, &apply, &reverse_patch).await? {
        Ok(mutated(&request.source))
    } else {
        Err(WriteError::PartialRevert)
    }
}

pub(crate) async fn commit(
    state: &AppState,
    request: &WorktreeCommitRequest,
) -> Result<DiffResult, WriteError> {
    let _permit = permit(state)?;
    let target = authorize(
        state,
        &request.session_id,
        &request.capability_token,
        &request.source,
    )
    .await?;
    if !target.staged {
        return Err(WriteError::NotAllowed);
    }
    let message = request.message.trim();
    if message.is_empty() || message.len() > MAX_COMMIT_MESSAGE_BYTES {
        return Err(WriteError::InvalidMessage);
    }
    match git_status(
        &target.repo,
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
        &target.repo,
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
    let commit = git::single_line(&target.repo, &["rev-parse", "--verify", "HEAD"])
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
    let text = String::from_utf8_lossy(stderr);
    let Some(line) = text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .next_back()
    else {
        return WriteError::CommitFailed;
    };
    let detail: String = line
        .chars()
        .filter(|character| !character.is_control())
        .take(MAX_HOOK_DETAIL_CHARS)
        .collect();
    if detail.trim().is_empty() {
        WriteError::CommitFailed
    } else {
        WriteError::CommitRejected(detail)
    }
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
async fn revert_paths(target: &Target, paths: &[String]) -> Result<(), WriteError> {
    let in_index = listed_paths(&target.repo, &["ls-files", "-z"], paths).await?;
    if !target.staged {
        require_all(paths, &in_index)?;
        return run_checked(&target.repo, &["restore", "--worktree"], paths).await;
    }
    let head = head_paths(&target.repo, paths).await?;
    let (in_head, added): (Vec<String>, Vec<String>) =
        paths.iter().cloned().partition(|path| head.contains(path));
    require_all(&added, &in_index)?;
    run_if_any(
        &target.repo,
        &["restore", "--staged", "--worktree", "--source=HEAD"],
        &in_head,
    )
    .await?;
    // A file staged as new has no HEAD version to restore; discarding it
    // removes the index entry and the working-tree copy. Once the restore
    // above has run, a failure here leaves a half-reverted rename.
    run_if_any(
        &target.repo,
        &["rm", "-f", "-q", "--ignore-unmatch"],
        &added,
    )
    .await
    .map_err(|error| {
        if in_head.is_empty() {
            error
        } else {
            WriteError::PartialRevert
        }
    })
}

/// The subset of `paths` that are blobs in HEAD's tree (`-r`, so a directory
/// lists its files and never itself). An unborn branch has no HEAD tree, so
/// nothing is in it.
async fn head_paths(repo: &Path, paths: &[String]) -> Result<HashSet<String>, WriteError> {
    match listed_paths(repo, &["ls-tree", "-r", "-z", "--name-only", "HEAD"], paths).await {
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

/// Runs a NUL-delimited listing (`ls-files -z`, `ls-tree -r -z`) over `paths`
/// as literal pathspecs and returns the names Git printed. A path that names
/// a directory lists its children, none of which equal the path itself, so
/// it is never classified as tracked.
async fn listed_paths(
    repo: &Path,
    arguments: &[&str],
    paths: &[String],
) -> Result<HashSet<String>, WriteError> {
    let arguments = with_paths(arguments, paths);
    let borrowed: Vec<&str> = arguments.iter().map(String::as_str).collect();
    let (stdout, status) = git::capture(
        repo,
        &borrowed,
        Access::ReadOnly,
        None,
        MAX_STATUS_OUTPUT_BYTES,
    )
    .await
    .map_err(|()| WriteError::Failed)?;
    if !status.success() {
        return Err(WriteError::Failed);
    }
    Ok(stdout
        .split(|byte| *byte == 0)
        .filter(|name| !name.is_empty())
        .filter_map(|name| std::str::from_utf8(name).ok())
        .map(str::to_owned)
        .collect())
}

fn with_paths(arguments: &[&str], paths: &[String]) -> Vec<String> {
    let mut result: Vec<String> = arguments.iter().map(|value| (*value).to_owned()).collect();
    result.push("--".to_owned());
    result.extend(paths.iter().map(|path| literal_pathspec(path)));
    result
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

/// Runs a mutating Git command over `paths` (as literal pathspecs after
/// `--`) and requires success.
async fn run_checked(repo: &Path, arguments: &[&str], paths: &[String]) -> Result<(), WriteError> {
    let arguments = with_paths(arguments, paths);
    let borrowed: Vec<&str> = arguments.iter().map(String::as_str).collect();
    if git_status(repo, &borrowed, Access::Mutating, None)
        .await?
        .success()
    {
        Ok(())
    } else {
        Err(WriteError::Failed)
    }
}

async fn run_if_any(repo: &Path, arguments: &[&str], paths: &[String]) -> Result<(), WriteError> {
    if paths.is_empty() {
        Ok(())
    } else {
        run_checked(repo, arguments, paths).await
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
        HunkRef, WriteError, commit_rejection, header_names_path, parse_hunk_header,
        select_hunk_patch, unquote_c_style, validate_repo_relative_path,
    };

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
