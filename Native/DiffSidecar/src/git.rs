//! The one way the sidecar runs Git.
//!
//! Every invocation goes through [`command`], so the process shape (`-C
//! repo`, no terminal prompts, no inherited stdin, discarded stderr) and the
//! shared deadline live in one place. Read-only invocations also set
//! `GIT_OPTIONAL_LOCKS=0`: a diff must never refresh `.git/index` stat data,
//! which a repository watcher would otherwise report as another change.

use std::path::Path;
use std::process::{ExitStatus, Stdio};

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::{ChildStdout, Command};
use tokio::time::Instant;

use crate::server::SESSION_GIT_TIMEOUT;

/// Whether an invocation may change the repository.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Access {
    ReadOnly,
    Mutating,
}

/// Builds a Git command for `repo` with stdout piped and stdin closed. Callers
/// that feed stdin (see [`capture`]) reopen it as a pipe.
pub(crate) fn command(repo: &Path, arguments: &[&str], access: Access) -> Command {
    let mut command = Command::new("/usr/bin/git");
    command
        .arg("-C")
        .arg(repo)
        .args(arguments)
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    if access == Access::ReadOnly {
        command.env("GIT_OPTIONAL_LOCKS", "0");
    }
    command
}

/// Spawns `command`, hands its stdout to `consume`, and waits for exit, all
/// under one [`SESSION_GIT_TIMEOUT`] deadline. Any failure or timeout kills
/// the child; `stdin`, when given, is written from a task so a child that
/// produces output before reading its input cannot deadlock the pipe.
pub(crate) async fn run<T, C, F>(
    mut command: Command,
    stdin: Option<&[u8]>,
    consume: C,
) -> Result<(T, ExitStatus), ()>
where
    C: FnOnce(ChildStdout) -> F,
    F: Future<Output = Result<T, ()>>,
{
    if stdin.is_some() {
        command.stdin(Stdio::piped());
    }
    let mut child = command.spawn().map_err(|_| ())?;
    let Some(stdout) = child.stdout.take() else {
        let _ = child.kill().await;
        return Err(());
    };
    let writer = match (stdin, child.stdin.take()) {
        (Some(bytes), Some(mut handle)) => {
            let bytes = bytes.to_vec();
            Some(tokio::spawn(async move {
                let written = handle.write_all(&bytes).await.is_ok();
                drop(handle);
                written
            }))
        }
        (Some(_), None) => {
            let _ = child.kill().await;
            return Err(());
        }
        (None, _) => None,
    };
    let deadline = Instant::now() + SESSION_GIT_TIMEOUT;
    let outcome = async {
        let value = tokio::time::timeout_at(deadline, consume(stdout))
            .await
            .map_err(|_| ())??;
        let status = tokio::time::timeout_at(deadline, child.wait())
            .await
            .map_err(|_| ())?
            .map_err(|_| ())?;
        Ok((value, status))
    }
    .await;
    if outcome.is_err() {
        let _ = child.kill().await;
    }
    if let Some(writer) = writer
        && !writer.await.unwrap_or(false)
    {
        return Err(());
    }
    outcome
}

/// Runs Git and collects at most `limit` bytes of stdout; more is a failure
/// (and kills the child) rather than an unbounded buffer.
pub(crate) async fn capture(
    repo: &Path,
    arguments: &[&str],
    access: Access,
    stdin: Option<&[u8]>,
    limit: usize,
) -> Result<(Vec<u8>, ExitStatus), ()> {
    run(
        command(repo, arguments, access),
        stdin,
        |stdout| async move {
            let mut output = Vec::new();
            stdout
                .take(limit as u64 + 1)
                .read_to_end(&mut output)
                .await
                .map_err(|_| ())?;
            if output.len() > limit {
                return Err(());
            }
            Ok(output)
        },
    )
    .await
}

/// Runs a read-only Git query that answers with one short line, such as
/// `rev-parse`. Empty, multi-line, oversized, or failing output is an error.
pub(crate) async fn single_line(repo: &Path, arguments: &[&str]) -> Result<String, ()> {
    let (stdout, status) = capture(repo, arguments, Access::ReadOnly, None, 4096).await?;
    if !status.success() {
        return Err(());
    }
    let line = String::from_utf8(stdout).map_err(|_| ())?.trim().to_owned();
    if line.is_empty() || line.contains(['\r', '\n']) {
        return Err(());
    }
    Ok(line)
}
