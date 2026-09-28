//! The one way the sidecar runs Git.
//!
//! Every invocation goes through [`command`], so the process shape (`-C
//! repo`, no terminal prompts, no inherited stdin, discarded stderr, no
//! inherited repository-location environment) and the shared deadline live
//! in one place. Read-only invocations also set `GIT_OPTIONAL_LOCKS=0`: a diff
//! must never refresh `.git/index` stat data, which a repository watcher would
//! otherwise report as another change.

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

/// Environment variables that redirect Git to another repository, index,
/// object store, or configuration. The host process may carry them (a
/// terminal inside `git rebase -i`, a hook, a `GIT_DIR` export); every
/// sidecar command targets exactly the repository named by `-C`.
const REPOSITORY_ENVIRONMENT: [&str; 10] = [
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_CONFIG_PARAMETERS",
    "GIT_CONFIG_COUNT",
    "GIT_CEILING_DIRECTORIES",
    "GIT_NAMESPACE",
    "GIT_COMMON_DIR",
];

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
    for name in REPOSITORY_ENVIRONMENT {
        command.env_remove(name);
    }
    for (name, _) in std::env::vars_os() {
        if name.to_str().is_some_and(|name| {
            name.starts_with("GIT_CONFIG_KEY_") || name.starts_with("GIT_CONFIG_VALUE_")
        }) {
            command.env_remove(name);
        }
    }
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
    command: Command,
    stdin: Option<&[u8]>,
    consume: C,
) -> Result<(T, ExitStatus), ()>
where
    C: FnOnce(ChildStdout) -> F,
    F: Future<Output = Result<T, ()>>,
{
    run_with_stderr(command, stdin, consume, None)
        .await
        .map(|(value, _, status)| (value, status))
}

/// [`run`] that also collects up to `stderr_limit` bytes of the child's
/// stderr when the command was built with `stderr(Stdio::piped())`; output
/// past the limit is dropped, not an error. A command with its own process
/// group (see [`own_process_group`]) has that whole group killed whenever the
/// child is.
pub(crate) async fn run_with_stderr<T, C, F>(
    mut command: Command,
    stdin: Option<&[u8]>,
    consume: C,
    stderr_limit: Option<usize>,
) -> Result<(T, Vec<u8>, ExitStatus), ()>
where
    C: FnOnce(ChildStdout) -> F,
    F: Future<Output = Result<T, ()>>,
{
    if stdin.is_some() {
        command.stdin(Stdio::piped());
    }
    let mut child = command.spawn().map_err(|_| ())?;
    let mut group = ProcessGroupGuard::for_child(&child);
    let Some(stdout) = child.stdout.take() else {
        let _ = child.kill().await;
        return Err(());
    };
    let stderr = match (stderr_limit, child.stderr.take()) {
        (Some(limit), Some(mut handle)) => Some(tokio::spawn(async move {
            let mut output = Vec::new();
            let _ = (&mut handle)
                .take(limit as u64)
                .read_to_end(&mut output)
                .await;
            // Keep draining so a chatty child never blocks on a full pipe.
            let _ = tokio::io::copy(&mut handle, &mut tokio::io::sink()).await;
            output
        })),
        _ => None,
    };
    let writer = match (stdin, child.stdin.take()) {
        (Some(bytes), Some(mut handle)) => {
            let bytes = bytes.to_vec();
            Some(tokio::spawn(async move {
                let _ = handle.write_all(&bytes).await;
                drop(handle);
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
    group.disarm_if(outcome.is_ok());
    drop(group);
    // A child that exits before draining its stdin (`git apply` rejecting a
    // header, `git --version`) closes the pipe under the writer. Its exit
    // status is the real result, so the writer is only joined, never
    // consulted; a child that did not finish already failed above.
    if let Some(writer) = writer {
        let _ = writer.await;
    }
    let (value, status) = outcome?;
    let stderr = match stderr {
        Some(task) => tokio::time::timeout_at(deadline, task)
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or_default(),
        None => Vec::new(),
    };
    Ok((value, stderr, status))
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
        |stdout| async move { read_limited(stdout, limit).await },
    )
    .await
}

/// [`capture`] for a mutating command that may run hooks: the command gets
/// its own process group (killed as a whole on timeout or cancellation) and
/// up to `stderr_limit` bytes of its stderr come back with the status.
pub(crate) async fn capture_with_hooks(
    repo: &Path,
    arguments: &[&str],
    stdin: Option<&[u8]>,
    limit: usize,
    stderr_limit: usize,
) -> Result<(Vec<u8>, Vec<u8>, ExitStatus), ()> {
    let mut command = command(repo, arguments, Access::Mutating);
    command.stderr(Stdio::piped());
    own_process_group(&mut command);
    run_with_stderr(
        command,
        stdin,
        |stdout| async move { read_limited(stdout, limit).await },
        Some(stderr_limit),
    )
    .await
}

async fn read_limited(stdout: ChildStdout, limit: usize) -> Result<Vec<u8>, ()> {
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
}

/// Places the child in a new process group so that everything it spawns
/// (hooks and their children) can be killed with it.
#[cfg(unix)]
fn own_process_group(command: &mut Command) {
    command.process_group(0);
}

#[cfg(not(unix))]
fn own_process_group(_command: &mut Command) {}

/// Kills the child's process group on drop unless disarmed. Only meaningful
/// for a child started with [`own_process_group`]: for any other child the
/// group is the sidecar's own and the guard stays inert.
struct ProcessGroupGuard {
    #[cfg(unix)]
    group: Option<rustix::process::Pid>,
}

impl ProcessGroupGuard {
    fn for_child(child: &tokio::process::Child) -> Self {
        #[cfg(unix)]
        {
            let group = child
                .id()
                .and_then(|id| rustix::process::Pid::from_raw(i32::try_from(id).ok()?))
                .filter(|pid| {
                    rustix::process::getpgid(Some(*pid)).is_ok_and(|group| group == *pid)
                });
            Self { group }
        }
        #[cfg(not(unix))]
        {
            let _ = child;
            Self {}
        }
    }

    fn disarm_if(&mut self, finished: bool) {
        #[cfg(unix)]
        if finished {
            self.group = None;
        }
        #[cfg(not(unix))]
        let _ = finished;
    }
}

impl Drop for ProcessGroupGuard {
    fn drop(&mut self) {
        #[cfg(unix)]
        if let Some(group) = self.group {
            let _ = rustix::process::kill_process_group(group, rustix::process::Signal::KILL);
        }
    }
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

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::{Access, capture, command};

    #[tokio::test]
    async fn a_child_that_exits_before_reading_stdin_still_reports_its_status() {
        // `git --version` never reads stdin, so a megabyte of input hits a
        // closed pipe; the exit status is the result, not the short write.
        let input = vec![b'x'; 1024 * 1024];
        let (stdout, status) = capture(
            Path::new("."),
            &["--version"],
            Access::ReadOnly,
            Some(&input),
            4096,
        )
        .await
        .expect("git ran");
        assert!(status.success());
        assert!(stdout.starts_with(b"git version"));
    }

    #[test]
    fn repository_location_environment_is_cleared() {
        let command = command(Path::new("."), &["status"], Access::ReadOnly);
        let cleared: Vec<&std::ffi::OsStr> = command
            .as_std()
            .get_envs()
            .filter(|(_, value)| value.is_none())
            .map(|(name, _)| name)
            .collect();
        for name in [
            "GIT_DIR",
            "GIT_WORK_TREE",
            "GIT_INDEX_FILE",
            "GIT_OBJECT_DIRECTORY",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES",
            "GIT_CONFIG_PARAMETERS",
            "GIT_CONFIG_COUNT",
            "GIT_CEILING_DIRECTORIES",
            "GIT_NAMESPACE",
        ] {
            assert!(cleared.contains(&std::ffi::OsStr::new(name)), "{name}");
        }
    }
}
