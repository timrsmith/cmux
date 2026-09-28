//! Working-tree and index mutations for open `unstaged` and `staged` sessions.
//!
//! Every command re-derives its inputs on the sidecar side: paths are
//! validated as repository-relative and must already be known to Git, hunks
//! are re-read from `git diff` and matched by header before `git apply -R`
//! runs, and nothing supplied by the page is ever passed to Git as patch
//! text. Authorization requires a valid capability token, a repository in
//! that token's allow-list, and an open session owned by the token whose
//! repository is the one being mutated.

use std::borrow::Cow;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::process::ExitStatus;

use crate::git::{self, Access};
use crate::manifest::valid_token;
use crate::protocol::{
    CommitResult, DiffResult, DiffSource, HunkRef, WorktreeCommitRequest, WorktreeFileRequest,
    WorktreeHunkRequest, WorktreeMutated,
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum WriteError {
    NotAllowed,
    InvalidPath,
    InvalidMessage,
    StaleHunk,
    Conflict,
    NothingToCommit,
    CommitFailed,
    Failed,
}

impl WriteError {
    pub(crate) fn code(self) -> &'static str {
        match self {
            Self::NotAllowed => "notAllowed",
            Self::InvalidPath => "invalidPath",
            Self::InvalidMessage => "invalidMessage",
            Self::StaleHunk => "staleHunk",
            Self::Conflict => "conflict",
            Self::NothingToCommit => "nothingToCommit",
            Self::CommitFailed => "commitFailed",
            Self::Failed => "worktreeWriteFailed",
        }
    }

    pub(crate) fn message(self) -> &'static str {
        match self {
            Self::NotAllowed => "Working-tree change is not authorized",
            Self::InvalidPath => "Path must be relative to the repository",
            Self::InvalidMessage => "Commit message is empty or too long",
            Self::StaleHunk => "The hunk no longer matches the working tree",
            Self::Conflict => "The change could not be applied cleanly",
            Self::NothingToCommit => "There are no staged changes to commit",
            Self::CommitFailed => "Git could not create the commit",
            Self::Failed => "Could not update the working tree",
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
    let target = authorize(
        state,
        &request.session_id,
        &request.capability_token,
        &request.source,
    )
    .await?;
    let paths = file_paths(request)?;
    let _permit = permit(state)?;
    match op {
        FileOp::Stage => run_checked(&target.repo, &["add"], &paths).await?,
        FileOp::Unstage => run_checked(&target.repo, &["restore", "--staged"], &paths).await?,
        FileOp::Revert => revert_paths(&target, &paths).await?,
    }
    Ok(mutated(&request.source))
}

pub(crate) async fn revert_hunk(
    state: &AppState,
    request: &WorktreeHunkRequest,
) -> Result<DiffResult, WriteError> {
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
    let _permit = permit(state)?;
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
    let reverse_patch = select_hunk_patch(&diff, request.hunk).ok_or(WriteError::StaleHunk)?;
    let mut apply = vec!["apply", "-R", "--whitespace=nowarn"];
    if target.staged {
        apply.push("--index");
    }
    if git_status(&target.repo, &apply, Access::Mutating, Some(&reverse_patch))
        .await?
        .success()
    {
        Ok(mutated(&request.source))
    } else {
        Err(WriteError::Conflict)
    }
}

pub(crate) async fn commit(
    state: &AppState,
    request: &WorktreeCommitRequest,
) -> Result<DiffResult, WriteError> {
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
    let _permit = permit(state)?;
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
    if !git_status(
        &target.repo,
        &["commit", "--quiet", "--cleanup=whitespace", "-F", "-"],
        Access::Mutating,
        Some(&body),
    )
    .await?
    .success()
    {
        return Err(WriteError::CommitFailed);
    }
    let commit = git::single_line(&target.repo, &["rev-parse", "--verify", "HEAD"])
        .await
        .map_err(|()| WriteError::Failed)?;
    if !(40..=64).contains(&commit.len()) || !commit.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(WriteError::Failed);
    }
    Ok(DiffResult::Committed(CommitResult { commit }))
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
/// allowed for the repository, and the session must be open, owned by the
/// token, and bound to the same canonical repository.
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
        || !session_owned_by(state, session_id, token, &repo).await
    {
        return Err(WriteError::NotAllowed);
    }
    Ok(Target { repo, staged })
}

async fn session_owned_by(state: &AppState, session_id: &str, token: &str, repo: &Path) -> bool {
    let Ok(Some(owner)) = read_session_owner(&state.config.root, session_id) else {
        return false;
    };
    if owner.capability_token != token || owner.repo_root.as_deref().map(Path::new) != Some(repo) {
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

/// Discards the changes to `paths`. An unstaged session restores the index
/// copy of index-tracked files; a staged session restores the HEAD copy of
/// files HEAD knows and removes files staged as new.
///
/// A path Git knows nothing about is refused. A `git diff` session never
/// lists untracked files, so such a path can only come from the page, and
/// honoring it (with `git clean`) would delete an arbitrary untracked file.
async fn revert_paths(target: &Target, paths: &[String]) -> Result<(), WriteError> {
    let in_index = listed_paths(&target.repo, &["ls-files", "-z"], paths).await?;
    if !target.staged {
        if paths.iter().any(|path| !in_index.contains(path)) {
            return Err(WriteError::InvalidPath);
        }
        return run_checked(&target.repo, &["restore", "--worktree"], paths).await;
    }
    let head = head_paths(&target.repo, paths).await?;
    let (in_head, added): (Vec<String>, Vec<String>) =
        paths.iter().cloned().partition(|path| head.contains(path));
    if added.iter().any(|path| !in_index.contains(path)) {
        return Err(WriteError::InvalidPath);
    }
    run_if_any(
        &target.repo,
        &["restore", "--staged", "--worktree", "--source=HEAD"],
        &in_head,
    )
    .await?;
    // A file staged as new has no HEAD version to restore; discarding it
    // removes the index entry and the working-tree copy.
    run_if_any(
        &target.repo,
        &["rm", "-f", "-q", "--ignore-unmatch"],
        &added,
    )
    .await
}

/// The subset of `paths` present in HEAD's tree. An unborn branch has no HEAD
/// tree, so nothing is in it.
async fn head_paths(repo: &Path, paths: &[String]) -> Result<HashSet<String>, WriteError> {
    match listed_paths(repo, &["ls-tree", "-z", "--name-only", "HEAD"], paths).await {
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

/// Runs a NUL-delimited listing (`ls-files -z`, `ls-tree -z`) over `paths` as
/// literal pathspecs and returns the names Git printed. A path that names a
/// directory lists its children, none of which equal the path itself, so it
/// is never classified as tracked.
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

/// Builds a single-hunk patch from one file's unified diff: the file header
/// (everything before the first `@@` line) followed by the hunk whose header
/// ranges equal `wanted`. Returns `None` when no hunk matches.
pub(crate) fn select_hunk_patch(diff: &[u8], wanted: HunkRef) -> Option<Vec<u8>> {
    let mut hunk_starts = Vec::new();
    let mut offset = 0;
    for line in diff.split_inclusive(|byte| *byte == b'\n') {
        if line.starts_with(b"@@ ") {
            hunk_starts.push(offset);
        }
        offset += line.len();
    }
    let header = content_only_header(&diff[..*hunk_starts.first()?])?;
    for (index, start) in hunk_starts.iter().enumerate() {
        let end = hunk_starts.get(index + 1).copied().unwrap_or(diff.len());
        let hunk = &diff[*start..end];
        let header_line = hunk.split(|byte| *byte == b'\n').next()?;
        if parse_hunk_header(header_line) == Some(wanted) {
            let mut patch = Vec::with_capacity(header.len() + hunk.len() + 1);
            patch.extend_from_slice(&header);
            patch.extend_from_slice(hunk);
            if !patch.ends_with(b"\n") {
                patch.push(b'\n');
            }
            return Some(patch);
        }
    }
    None
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
    let new_side = new_side.strip_suffix(b"\n").unwrap_or(new_side);
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
        HunkRef, WriteError, parse_hunk_header, select_hunk_patch, validate_repo_relative_path,
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
        let patch = select_hunk_patch(diff, second).expect("second hunk");
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
        assert!(select_hunk_patch(diff, stale).is_none());
        assert!(select_hunk_patch(b"", second).is_none());
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
        let patch = select_hunk_patch(diff, hunk).expect("rename hunk");
        assert_eq!(
            String::from_utf8(patch).expect("utf8 patch"),
            "diff --git a/new.txt b/new.txt\n--- a/new.txt\n+++ b/new.txt\n@@ -8,3 +8,3 @@\n l8\n-l9\n+l9 changed\n"
        );
        let quoted = b"diff --git \"a/old\\ttab.txt\" \"b/new\\ttab.txt\"\nrename from \"old\\ttab.txt\"\nrename to \"new\\ttab.txt\"\n--- \"a/old\\ttab.txt\"\n+++ \"b/new\\ttab.txt\"\n@@ -8,3 +8,3 @@\n l8\n-l9\n+l9 changed\n";
        let patch = select_hunk_patch(quoted, hunk).expect("quoted rename hunk");
        assert!(
            String::from_utf8(patch)
                .expect("utf8 patch")
                .starts_with("diff --git \"a/new\\ttab.txt\" \"b/new\\ttab.txt\"\n--- \"a/new\\ttab.txt\"\n+++ \"b/new\\ttab.txt\"\n@@ -8,3 +8,3 @@\n")
        );
    }
}
