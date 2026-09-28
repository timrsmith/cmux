//! Forge (GitHub / GitLab) integration for open working-tree sessions: which
//! forge a remote points at, whether its CLI (`gh` / `glab`) is installed and
//! signed in, and the pull request for the current branch.
//!
//! The CLI executable is resolved only from a fixed candidate list (the
//! sidecar's own `PATH` plus the two Homebrew prefixes), never from anything
//! the page supplies, and every invocation runs without a shell, with the
//! repository-location environment scrubbed, bounded output, and a deadline.

use std::path::{Path, PathBuf};
use std::process::ExitStatus;
use std::time::Duration;

use tokio::process::Command;

use crate::git;
use crate::protocol::{ChecksSummary, ForgeCliKind, PullRequestSummary, RepositoryHostKind};

/// Every forge CLI call is a network call: `auth status` verifies the stored
/// token against the API, and the request lookup and creation are one API
/// round trip each. This is the most any single call may take; a chained
/// flow passes what is left of its own budget instead.
pub(crate) const FORGE_CLI_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_FORGE_STDOUT_BYTES: usize = 4 * 1024 * 1024;
const MAX_FORGE_STDERR_BYTES: usize = 64 * 1024;
const EXTRA_CLI_DIRECTORIES: [&str; 2] = ["/opt/homebrew/bin", "/usr/local/bin"];

impl ForgeCliKind {
    pub(crate) fn executable_name(self) -> &'static str {
        match self {
            Self::Gh => "gh",
            Self::Glab => "glab",
        }
    }

    pub(crate) fn for_host(host: RepositoryHostKind) -> Option<Self> {
        match host {
            RepositoryHostKind::Github => Some(Self::Gh),
            RepositoryHostKind::Gitlab => Some(Self::Glab),
            RepositoryHostKind::Other | RepositoryHostKind::None => None,
        }
    }
}

/// Classifies a remote URL by its host: `https://`, `ssh://`, `git://` and
/// scp-like `user@host:path` forms are all understood.
#[must_use]
pub(crate) fn host_kind(remote_url: Option<&str>) -> RepositoryHostKind {
    let Some(url) = remote_url.map(str::trim).filter(|url| !url.is_empty()) else {
        return RepositoryHostKind::None;
    };
    let Some(host) = remote_host(url) else {
        return RepositoryHostKind::Other;
    };
    let host = host.to_ascii_lowercase();
    if host == "github.com" || host.ends_with(".github.com") {
        RepositoryHostKind::Github
    } else if host == "gitlab.com" || host.ends_with(".gitlab.com") || host.starts_with("gitlab.") {
        RepositoryHostKind::Gitlab
    } else {
        RepositoryHostKind::Other
    }
}

/// The host part of a remote URL, or `None` for a local path.
fn remote_host(url: &str) -> Option<&str> {
    if let Some((scheme, rest)) = url.split_once("://") {
        if !scheme
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || character == '+')
        {
            return None;
        }
        let authority = rest.split(['/', '?', '#']).next()?;
        let host = authority
            .rsplit_once('@')
            .map_or(authority, |(_, host)| host);
        let host = match host.rsplit_once(':') {
            Some((name, port))
                if !port.is_empty() && port.chars().all(|character| character.is_ascii_digit()) =>
            {
                name
            }
            _ => host,
        };
        return (!host.is_empty()).then_some(host.trim_matches(['[', ']']));
    }
    // scp-like: `[user@]host:path`, where the path has no leading slash
    // before the colon. A Windows drive or a bare path has no `@` and no
    // `:` before the first `/`.
    let (authority, _) = url.split_once(':')?;
    if authority.contains('/') {
        return None;
    }
    let host = authority
        .rsplit_once('@')
        .map_or(authority, |(_, host)| host);
    (!host.is_empty()).then_some(host)
}

/// Locates `kind`'s executable among the fixed candidate directories: the
/// entries of `path_env` (the sidecar's own `PATH`) followed by the Homebrew
/// prefixes. Only a regular, executable file named exactly `gh` or `glab`
/// qualifies.
#[must_use]
pub(crate) fn locate_cli(kind: ForgeCliKind, path_env: Option<&str>) -> Option<PathBuf> {
    let name = kind.executable_name();
    let from_path = path_env
        .unwrap_or_default()
        .split(':')
        .filter(|directory| !directory.is_empty())
        .map(PathBuf::from);
    from_path
        .chain(EXTRA_CLI_DIRECTORIES.iter().map(PathBuf::from))
        .filter(|directory| directory.is_absolute())
        .map(|directory| directory.join(name))
        .find(|candidate| is_executable_file(candidate))
}

fn is_executable_file(path: &Path) -> bool {
    let Ok(metadata) = std::fs::metadata(path) else {
        return false;
    };
    if !metadata.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}

/// A resolved forge CLI bound to one repository.
pub(crate) struct ForgeCli {
    pub(crate) kind: ForgeCliKind,
    executable: PathBuf,
    repo: PathBuf,
}

pub(crate) struct CliOutput {
    pub(crate) stdout: Vec<u8>,
    pub(crate) stderr: Vec<u8>,
    pub(crate) status: ExitStatus,
}

impl CliOutput {
    pub(crate) fn stdout_text(&self) -> String {
        String::from_utf8_lossy(&self.stdout).into_owned()
    }

    pub(crate) fn stderr_text(&self) -> String {
        String::from_utf8_lossy(&self.stderr).into_owned()
    }
}

impl ForgeCli {
    pub(crate) fn locate(kind: ForgeCliKind, repo: &Path) -> Option<Self> {
        let path_env = std::env::var("PATH").ok();
        let executable = locate_cli(kind, path_env.as_deref())?;
        Some(Self {
            kind,
            executable,
            repo: repo.to_path_buf(),
        })
    }

    fn command(&self, arguments: &[&str]) -> Command {
        let mut command = Command::new(&self.executable);
        command.current_dir(&self.repo).args(arguments);
        git::scrub_repository_environment(&mut command);
        command
            .env("NO_COLOR", "1")
            .env("PAGER", "cat")
            .env("GH_PAGER", "cat")
            .env("GH_PROMPT_DISABLED", "1")
            .env("GH_NO_UPDATE_NOTIFIER", "1")
            .env("GLAB_CHECK_UPDATE", "false")
            .env("NO_PROMPT", "1");
        command
    }

    /// Runs the CLI within `timeout` and collects bounded output. Only a
    /// failure to run it at all (or the deadline) is `Err`; a non-zero exit
    /// is reported in `status`.
    pub(crate) async fn run(
        &self,
        arguments: &[&str],
        stdin: Option<&[u8]>,
        timeout: Duration,
    ) -> Result<CliOutput, ()> {
        let (stdout, stderr, status) = git::capture_command(
            self.command(arguments),
            stdin,
            MAX_FORGE_STDOUT_BYTES,
            MAX_FORGE_STDERR_BYTES,
            timeout,
        )
        .await?;
        Ok(CliOutput {
            stdout,
            stderr,
            status,
        })
    }

    /// Whether the CLI reports a signed-in account. Both CLIs check their
    /// stored token against the API and exit non-zero when no host is logged
    /// in (or the token no longer works).
    pub(crate) async fn is_authenticated(&self, timeout: Duration) -> bool {
        self.run(&["auth", "status"], None, timeout)
            .await
            .is_ok_and(|output| output.status.success())
    }

    /// The newest pull (merge) request whose source is `branch`, in any
    /// state, or `None` when the forge has none for it or the CLI cannot
    /// answer. The list form is used because `pr view <branch>` and `mr view
    /// <branch>` read an all-digit branch name as a request number.
    pub(crate) async fn pull_request(
        &self,
        branch: &str,
        timeout: Duration,
    ) -> Option<PullRequestSummary> {
        let output = match self.kind {
            ForgeCliKind::Gh => {
                self.run(
                    &[
                        "pr",
                        "list",
                        "--head",
                        branch,
                        "--state",
                        "all",
                        "--limit",
                        "1",
                        "--json",
                        "number,url,title,state,isDraft,baseRefName,reviewDecision,statusCheckRollup",
                    ],
                    None,
                    timeout,
                )
                .await
            }
            ForgeCliKind::Glab => {
                self.run(
                    &[
                        "mr",
                        "list",
                        "--source-branch",
                        branch,
                        "--all",
                        "--output",
                        "json",
                    ],
                    None,
                    timeout,
                )
                .await
            }
        }
        .ok()?;
        if !output.status.success() {
            return None;
        }
        first_listed_request(self.kind, &output.stdout)
    }
}

/// The first element of a `pr list --json` / `mr list --output json` array
/// (both CLIs list newest first), summarized; an empty array or anything
/// other than an array is `None`.
pub(crate) fn first_listed_request(
    kind: ForgeCliKind,
    stdout: &[u8],
) -> Option<PullRequestSummary> {
    let json: serde_json::Value = serde_json::from_slice(stdout).ok()?;
    let first = json.as_array()?.first()?;
    match kind {
        ForgeCliKind::Gh => parse_gh_pull_request(first),
        ForgeCliKind::Glab => parse_glab_merge_request(first),
    }
}

/// Reads one `gh pr list --json ...` element. Missing optional fields
/// degrade to `None`; a missing number or URL means no usable pull request.
pub(crate) fn parse_gh_pull_request(json: &serde_json::Value) -> Option<PullRequestSummary> {
    let number = json.get("number")?.as_u64()?;
    let url = json.get("url")?.as_str()?.to_owned();
    let state = match json.get("state").and_then(serde_json::Value::as_str) {
        Some("MERGED") => "merged",
        Some("CLOSED") => "closed",
        _ => "open",
    };
    let checks = json
        .get("statusCheckRollup")
        .and_then(serde_json::Value::as_array)
        .map(|rollup| summarize_gh_checks(rollup));
    Some(PullRequestSummary {
        number,
        url,
        title: string_field(json, "title"),
        state: state.to_owned(),
        is_draft: json
            .get("isDraft")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false),
        base_branch: string_field(json, "baseRefName"),
        review_decision: json
            .get("reviewDecision")
            .and_then(serde_json::Value::as_str)
            .filter(|decision| !decision.is_empty())
            .map(str::to_ascii_lowercase),
        checks,
    })
}

/// Counts a `statusCheckRollup` array. Check runs carry `status` and
/// `conclusion`; commit statuses carry `state`.
fn summarize_gh_checks(rollup: &[serde_json::Value]) -> ChecksSummary {
    let mut summary = ChecksSummary::default();
    for check in rollup {
        summary.total += 1;
        let conclusion = check
            .get("conclusion")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("");
        let state = check
            .get("state")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("");
        let verdict = if conclusion.is_empty() {
            state
        } else {
            conclusion
        };
        match verdict {
            "SUCCESS" | "NEUTRAL" | "SKIPPED" => summary.passed += 1,
            "FAILURE" | "ERROR" | "TIMED_OUT" | "CANCELLED" | "ACTION_REQUIRED"
            | "STARTUP_FAILURE" | "STALE" => summary.failed += 1,
            _ => summary.pending += 1,
        }
    }
    summary
}

/// Reads one `glab mr list --output json` element.
pub(crate) fn parse_glab_merge_request(json: &serde_json::Value) -> Option<PullRequestSummary> {
    let number = json.get("iid")?.as_u64()?;
    let url = json.get("web_url")?.as_str()?.to_owned();
    let state = match json.get("state").and_then(serde_json::Value::as_str) {
        Some("merged") => "merged",
        Some("closed" | "locked") => "closed",
        _ => "open",
    };
    let checks = json
        .get("head_pipeline")
        .and_then(|pipeline| pipeline.get("status"))
        .and_then(serde_json::Value::as_str)
        .map(|status| {
            let mut summary = ChecksSummary {
                total: 1,
                ..ChecksSummary::default()
            };
            match status {
                "success" | "skipped" => summary.passed = 1,
                "failed" | "canceled" => summary.failed = 1,
                _ => summary.pending = 1,
            }
            summary
        });
    Some(PullRequestSummary {
        number,
        url,
        title: string_field(json, "title"),
        state: state.to_owned(),
        is_draft: json
            .get("draft")
            .or_else(|| json.get("work_in_progress"))
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false),
        base_branch: string_field(json, "target_branch"),
        review_decision: None,
        checks,
    })
}

fn string_field(json: &serde_json::Value, key: &str) -> String {
    json.get(key)
        .and_then(serde_json::Value::as_str)
        .unwrap_or("")
        .to_owned()
}

/// The first `http(s)://` token in CLI output: both CLIs print the created
/// request's URL on its own line.
#[must_use]
pub(crate) fn first_url(text: &str) -> Option<&str> {
    text.split_whitespace()
        .find(|word| word.starts_with("https://") || word.starts_with("http://"))
        .map(|word| word.trim_end_matches(['.', ',', ')', ':']))
}

/// The request number at the end of a forge URL (`.../pull/42`,
/// `.../merge_requests/42`).
#[must_use]
pub(crate) fn number_from_url(url: &str) -> Option<u64> {
    url.trim_end_matches('/')
        .rsplit('/')
        .next()?
        .split(['?', '#'])
        .next()?
        .parse()
        .ok()
}

#[cfg(test)]
mod tests {
    use super::{
        ForgeCliKind, RepositoryHostKind, first_listed_request, first_url, host_kind, locate_cli,
        number_from_url, parse_gh_pull_request, parse_glab_merge_request,
    };

    #[test]
    fn host_kind_recognizes_https_and_ssh_forge_urls() {
        for url in [
            "https://github.com/acme/widgets.git",
            "git@github.com:acme/widgets.git",
            "ssh://git@github.com/acme/widgets.git",
            "ssh://git@github.com:22/acme/widgets.git",
            "https://user:token@github.com/acme/widgets",
            "git@enterprise.github.com:acme/widgets.git",
        ] {
            assert_eq!(host_kind(Some(url)), RepositoryHostKind::Github, "{url}");
        }
        for url in [
            "https://gitlab.com/acme/widgets.git",
            "git@gitlab.com:acme/widgets.git",
            "ssh://git@gitlab.example.com/acme/widgets.git",
            "https://gitlab.internal.example.com/acme/widgets.git",
        ] {
            assert_eq!(host_kind(Some(url)), RepositoryHostKind::Gitlab, "{url}");
        }
        for url in [
            "https://bitbucket.org/acme/widgets.git",
            "git@codeberg.org:acme/widgets.git",
            "/srv/git/widgets.git",
            "../bare.git",
            "file:///srv/git/widgets.git",
        ] {
            assert_eq!(host_kind(Some(url)), RepositoryHostKind::Other, "{url}");
        }
        assert_eq!(host_kind(None), RepositoryHostKind::None);
        assert_eq!(host_kind(Some("  ")), RepositoryHostKind::None);
    }

    #[test]
    fn cli_discovery_uses_only_the_fixed_candidate_directories() {
        let root = std::env::temp_dir().join(format!(
            "cmux-forge-cli-test-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        let on_path = root.join("on-path");
        let elsewhere = root.join("elsewhere");
        std::fs::create_dir_all(&on_path).expect("create dir");
        std::fs::create_dir_all(&elsewhere).expect("create dir");
        let script = b"#!/bin/sh\nexit 0\n";
        std::fs::write(on_path.join("gh"), script).expect("write gh");
        std::fs::write(on_path.join("glab.sh"), script).expect("write glab.sh");
        std::fs::write(elsewhere.join("glab"), script).expect("write glab");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            for file in [on_path.join("gh"), elsewhere.join("glab")] {
                std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755))
                    .expect("chmod");
            }
            // A non-executable `gh` never qualifies.
            std::fs::write(elsewhere.join("gh"), script).expect("write gh");
            std::fs::set_permissions(elsewhere.join("gh"), std::fs::Permissions::from_mode(0o644))
                .expect("chmod");
        }
        let path_env = format!("{}:relative/bin:", on_path.display());
        assert_eq!(
            locate_cli(ForgeCliKind::Gh, Some(&path_env)),
            Some(on_path.join("gh"))
        );
        // `glab` is not on PATH under its exact name, and `elsewhere` is not
        // a candidate directory even though a real executable lives there.
        let glab = locate_cli(ForgeCliKind::Glab, Some(&path_env));
        assert!(
            glab.is_none() || !glab.as_deref().unwrap().starts_with(&root),
            "{glab:?}"
        );
        let gh_elsewhere = locate_cli(ForgeCliKind::Gh, Some(&format!("{}", elsewhere.display())));
        assert!(
            gh_elsewhere.is_none() || !gh_elsewhere.as_deref().unwrap().starts_with(&root),
            "{gh_elsewhere:?}"
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn gh_pull_request_json_is_summarized() {
        let json = serde_json::json!({
            "number": 42,
            "url": "https://github.com/acme/widgets/pull/42",
            "title": "Add widgets",
            "state": "OPEN",
            "isDraft": true,
            "baseRefName": "main",
            "reviewDecision": "APPROVED",
            "statusCheckRollup": [
                {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS"},
                {"__typename": "CheckRun", "status": "IN_PROGRESS", "conclusion": ""},
                {"__typename": "StatusContext", "state": "FAILURE"},
                {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SKIPPED"}
            ]
        });
        let summary = parse_gh_pull_request(&json).expect("summary");
        assert_eq!(summary.number, 42);
        assert_eq!(summary.state, "open");
        assert!(summary.is_draft);
        assert_eq!(summary.base_branch, "main");
        assert_eq!(summary.review_decision.as_deref(), Some("approved"));
        let checks = summary.checks.expect("checks");
        assert_eq!(
            (checks.total, checks.passed, checks.failed, checks.pending),
            (4, 2, 1, 1)
        );
        let merged = parse_gh_pull_request(&serde_json::json!({
            "number": 7, "url": "https://x/pull/7", "state": "MERGED", "reviewDecision": ""
        }))
        .expect("merged");
        assert_eq!(merged.state, "merged");
        assert_eq!(merged.review_decision, None);
        assert_eq!(merged.checks, None);
        assert!(parse_gh_pull_request(&serde_json::json!({"title": "no number"})).is_none());
    }

    #[test]
    fn glab_merge_request_json_is_summarized() {
        let json = serde_json::json!({
            "iid": 9,
            "web_url": "https://gitlab.com/acme/widgets/-/merge_requests/9",
            "title": "Add widgets",
            "state": "opened",
            "draft": false,
            "target_branch": "main",
            "head_pipeline": {"status": "running"}
        });
        let summary = parse_glab_merge_request(&json).expect("summary");
        assert_eq!(summary.number, 9);
        assert_eq!(summary.state, "open");
        assert_eq!(summary.base_branch, "main");
        assert_eq!(summary.checks.map(|checks| checks.pending), Some(1));
    }

    #[test]
    fn listed_requests_take_the_first_element_and_an_empty_list_is_none() {
        assert!(first_listed_request(ForgeCliKind::Gh, b"[]").is_none());
        assert!(first_listed_request(ForgeCliKind::Glab, b"[]").is_none());
        // A bare object (the `view` shape) is not a listing.
        assert!(
            first_listed_request(
                ForgeCliKind::Gh,
                br#"{"number": 1, "url": "https://x/pull/1"}"#
            )
            .is_none()
        );
        assert!(first_listed_request(ForgeCliKind::Gh, b"not json").is_none());
        let newest = first_listed_request(
            ForgeCliKind::Gh,
            br#"[{"number": 5, "url": "https://x/pull/5", "state": "OPEN"}, {"number": 2, "url": "https://x/pull/2", "state": "CLOSED"}]"#,
        )
        .expect("summary");
        assert_eq!((newest.number, newest.state.as_str()), (5, "open"));
        let merge_request = first_listed_request(
            ForgeCliKind::Glab,
            br#"[{"iid": 9, "web_url": "https://gitlab.com/x/-/merge_requests/9", "state": "merged"}]"#,
        )
        .expect("summary");
        assert_eq!(
            (merge_request.number, merge_request.state.as_str()),
            (9, "merged")
        );
    }

    #[test]
    fn created_request_urls_yield_their_numbers() {
        assert_eq!(
            first_url(
                "Creating pull request for feat into main in acme/widgets\n\nhttps://github.com/acme/widgets/pull/42\n"
            ),
            Some("https://github.com/acme/widgets/pull/42")
        );
        assert_eq!(
            number_from_url("https://github.com/acme/widgets/pull/42"),
            Some(42)
        );
        assert_eq!(
            number_from_url("https://gitlab.com/acme/widgets/-/merge_requests/9/"),
            Some(9)
        );
        assert_eq!(
            number_from_url("https://github.com/acme/widgets/pulls"),
            None
        );
        assert_eq!(first_url("no url here"), None);
    }
}
