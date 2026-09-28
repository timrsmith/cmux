use std::io::{BufRead, BufReader, Write};
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Output, Stdio};

use futures_util::{SinkExt, StreamExt};

#[test]
fn rpc_uses_stdio_without_server_state() {
    let output = run_stdio_rpc(br#"{"id":"probe","version":1,"method":"protocolHandshake"}"#);
    assert!(output.status.success());
    let response: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("decode response");
    assert_eq!(response["id"], "probe");
    assert_eq!(response["result"]["type"], "handshake");
}

#[test]
fn rpc_returns_typed_failure_for_malformed_request() {
    let output = run_stdio_rpc(br#"{"id": "unclosed"#);
    assert!(output.status.success());
    assert_rpc_failure(&output, "invalidRequest");
}

#[test]
fn rpc_returns_typed_failure_for_oversized_request() {
    let output = run_stdio_rpc(&vec![b' '; 1024 * 1024 + 1]);
    assert!(output.status.success());
    assert_rpc_failure(&output, "requestTooLarge");
}

#[test]
fn rpc_accepts_request_at_one_mib_limit() {
    let mut request = br#"{"id":"limit","version":1,"method":"protocolHandshake"}"#.to_vec();
    request.resize(1024 * 1024, b' ');
    let output = run_stdio_rpc(&request);
    assert!(output.status.success());
    let response: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("decode limit response");
    assert_eq!(response["id"], "limit");
    assert_eq!(response["result"]["type"], "handshake");
}

#[cfg(unix)]
#[test]
fn cancelling_rpc_terminates_its_process_group_and_removes_partial_patch() {
    let root = std::env::temp_dir().join(format!(
        "cmux-diff-sidecar-cancel-test-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    let repo = create_large_changed_repo(&root);
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))
        .expect("secure root permissions");

    let token = "0123456789abcdef";
    write_cancellation_test_authorization(&root, &repo, token);

    let request = serde_json::to_vec(&serde_json::json!({
        "id": "cancel-session",
        "version": 1,
        "method": "sessionOpen",
        "params": {
            "source": {"kind": "unstaged", "repoRoot": repo},
            "capabilityToken": token
        }
    }))
    .expect("encode request");
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-diff-sidecar"))
        .arg("rpc")
        .arg("--root")
        .arg(&root)
        .arg("--cmux")
        .arg(env!("CARGO_BIN_EXE_diff-sidecar-test-host"))
        .arg("--process-group-ready")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .expect("start cancellable sidecar");
    let mut ready = String::new();
    BufReader::new(child.stderr.take().expect("sidecar stderr"))
        .read_line(&mut ready)
        .expect("read process-group readiness");
    assert_eq!(ready, "cmux-diff-sidecar-process-group-ready\n");
    child
        .stdin
        .take()
        .expect("sidecar stdin")
        .write_all(&request)
        .expect("write request");

    let sidecar_pid =
        rustix::process::Pid::from_raw(child.id().cast_signed()).expect("sidecar pid");
    let git_pid = wait_for_direct_child(child.id());
    assert_eq!(
        rustix::process::getpgid(Some(git_pid)).expect("git process group"),
        sidecar_pid
    );

    rustix::process::kill_process_group(sidecar_pid, rustix::process::Signal::TERM)
        .expect("terminate process group");
    let _ = child.wait().expect("reap sidecar");
    let _ = rustix::process::kill_process_group(sidecar_pid, rustix::process::Signal::KILL);
    assert_process_stopped(git_pid);
    assert!(
        std::fs::read_dir(&root)
            .expect("read sidecar root")
            .flatten()
            .all(|entry| {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                !(name.contains("diff-session-") && name.ends_with(".patch"))
            })
    );
    let _ = std::fs::remove_dir_all(root);
}

#[cfg(unix)]
fn assert_process_stopped(pid: rustix::process::Pid) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        if rustix::process::test_kill_process(pid).is_err() {
            return;
        }
        let status = Command::new("/bin/ps")
            .args(["-o", "stat=", "-p", &pid.as_raw_nonzero().to_string()])
            .output()
            .expect("inspect terminated git");
        if String::from_utf8_lossy(&status.stdout)
            .trim()
            .starts_with('Z')
        {
            return;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "git descendant remained live"
        );
        std::thread::yield_now();
    }
}

#[cfg(unix)]
fn create_large_changed_repo(root: &Path) -> std::path::PathBuf {
    let repo = root.join("repo");
    std::fs::create_dir_all(&repo).expect("create repo");
    run_git(&repo, &["init"]);
    run_git(&repo, &["config", "user.name", "cmux tests"]);
    run_git(&repo, &["config", "user.email", "cmux@example.invalid"]);
    let mut contents = vec![b'a'; 32 * 1024 * 1024];
    std::fs::write(repo.join("large.txt"), &contents).expect("write initial file");
    run_git(&repo, &["add", "large.txt"]);
    run_git(&repo, &["commit", "-m", "initial"]);
    let last_index = contents.len() - 1;
    contents[last_index] = b'b';
    std::fs::write(repo.join("large.txt"), contents).expect("write changed file");
    repo
}

#[cfg(unix)]
fn write_cancellation_test_authorization(root: &Path, repo: &Path, token: &str) {
    std::fs::write(
        root.join(format!(".manifest-{token}.json")),
        serde_json::to_vec(&serde_json::json!({"token": token, "files": []}))
            .expect("encode manifest"),
    )
    .expect("write manifest");
    std::fs::write(
        root.join(".branch-session-cancel-test.json"),
        serde_json::to_vec(&serde_json::json!({
            "token": token,
            "groupID": "cancel-test",
            "allowedRepoRoots": [repo]
        }))
        .expect("encode session"),
    )
    .expect("write session");
}

#[cfg(unix)]
fn wait_for_direct_child(parent_pid: u32) -> rustix::process::Pid {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    loop {
        let output = Command::new("/usr/bin/pgrep")
            .arg("-P")
            .arg(parent_pid.to_string())
            .output()
            .expect("inspect sidecar children");
        if let Some(pid) = String::from_utf8_lossy(&output.stdout)
            .lines()
            .find_map(|line| line.trim().parse::<i32>().ok())
            .and_then(rustix::process::Pid::from_raw)
        {
            return pid;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "git child did not start"
        );
        std::thread::yield_now();
    }
}

fn run_stdio_rpc(input: &[u8]) -> Output {
    let root = std::env::temp_dir().join(format!(
        "cmux-diff-sidecar-rpc-test-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    std::fs::create_dir_all(&root).expect("create root");
    #[cfg(unix)]
    {
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))
            .expect("secure root permissions");
    }

    let output = run_stdio_rpc_in_root(input, &root);
    assert!(!root.join(".server.json").exists());
    let _ = std::fs::remove_dir_all(root);
    output
}

fn run_stdio_rpc_in_root(input: &[u8], root: &Path) -> Output {
    // The host may carry repository-location variables (a terminal inside a
    // hook or `GIT_DIR` export). Every Git command the sidecar runs must
    // target the `-C` repository regardless, so each stdio test runs under
    // hostile values: honoring any of them fails the test.
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-diff-sidecar"))
        .arg("rpc")
        .arg("--root")
        .arg(root)
        .arg("--cmux")
        .arg(env!("CARGO_BIN_EXE_diff-sidecar-test-host"))
        .env("GIT_DIR", root.join("not-a-repository"))
        .env("GIT_WORK_TREE", root.join("not-a-work-tree"))
        .env("GIT_INDEX_FILE", root.join("not-an-index"))
        .env("GIT_CONFIG_COUNT", "1")
        .env("GIT_CONFIG_KEY_0", "diff.noprefix")
        .env("GIT_CONFIG_VALUE_0", "true")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("start stdio sidecar");
    child
        .stdin
        .take()
        .expect("sidecar stdin")
        .write_all(input)
        .expect("write request");
    child.wait_with_output().expect("wait for sidecar")
}

fn assert_rpc_failure(output: &Output, code: &str) {
    let response: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("decode typed failure");
    assert_eq!(response["id"], "__cmux_untrusted_request__");
    assert_eq!(response["version"], 1);
    assert!(response["result"].is_null());
    assert_eq!(response["error"]["code"], code);
}

#[test]
fn rpc_git_sessions_match_git_without_starting_a_server() {
    let root = std::env::temp_dir().join(format!(
        "cmux-diff-sidecar-session-test-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    let repo = root.join("repo");
    std::fs::create_dir_all(&repo).expect("create repo");
    #[cfg(unix)]
    {
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))
            .expect("secure root permissions");
    }
    run_git(&repo, &["init"]);
    run_git(&repo, &["config", "user.name", "cmux tests"]);
    run_git(&repo, &["config", "user.email", "cmux@example.invalid"]);
    std::fs::write(repo.join("story.txt"), b"one\n").expect("write initial file");
    run_git(&repo, &["add", "story.txt"]);
    run_git(&repo, &["commit", "-m", "initial"]);
    std::fs::write(repo.join("story.txt"), b"one\ntwo\n").expect("write changed file");

    let token = "0123456789abcdef";
    let shell = root.join("viewer.html");
    std::fs::write(&shell, b"<!doctype html>").expect("write shell");
    std::fs::write(
        root.join(format!(".manifest-{token}.json")),
        serde_json::to_vec(&serde_json::json!({
            "token": token,
            "files": [{
                "request_path": "/viewer.html",
                "file_path": shell,
                "mime_type": "text/html"
            }]
        }))
        .expect("encode manifest"),
    )
    .expect("write manifest");
    std::fs::write(
        root.join(".branch-session-session-test.json"),
        serde_json::to_vec(&serde_json::json!({
            "token": token,
            "groupID": "session-test",
            "allowedRepoRoots": [&repo]
        }))
        .expect("encode session"),
    )
    .expect("write session");

    assert_overlapping_sessions_remain_independently_closable(&root, &repo, token);

    assert_session_matches_git(
        &root,
        &repo,
        token,
        &serde_json::json!({"kind": "unstaged", "repoRoot": repo}),
        &["diff", "--no-ext-diff", "--no-color", "--binary", "--"],
    );
    run_git(&repo, &["add", "story.txt"]);
    assert_session_matches_git(
        &root,
        &repo,
        token,
        &serde_json::json!({"kind": "staged", "repoRoot": repo}),
        &[
            "diff",
            "--no-ext-diff",
            "--no-color",
            "--binary",
            "--cached",
            "--",
        ],
    );
    assert_session_matches_git(
        &root,
        &repo,
        token,
        &serde_json::json!({"kind": "branch", "repoRoot": repo, "baseRef": "HEAD"}),
        &[
            "diff",
            "--no-ext-diff",
            "--no-color",
            "--binary",
            "HEAD",
            "--",
        ],
    );
    assert_session_matches_git(
        &root,
        &repo,
        token,
        &serde_json::json!({"kind": "branch", "repoRoot": repo}),
        &[
            "diff",
            "--no-ext-diff",
            "--no-color",
            "--binary",
            "HEAD",
            "--",
        ],
    );
    assert!(!root.join(".server.json").exists());
    let _ = std::fs::remove_dir_all(root);
}

fn assert_overlapping_sessions_remain_independently_closable(
    root: &Path,
    repo: &Path,
    token: &str,
) {
    let source = serde_json::json!({"kind": "unstaged", "repoRoot": repo});
    let git_arguments = ["diff", "--no-ext-diff", "--no-color", "--binary", "--"];
    let (abandoned_session, abandoned_path) =
        open_session_matches_git(root, repo, token, &source, &git_arguments);
    let (replacement_session, replacement_path) =
        open_session_matches_git(root, repo, token, &source, &git_arguments);
    assert!(root.join(abandoned_path.trim_start_matches('/')).exists());
    let manifest: serde_json::Value = serde_json::from_slice(
        &std::fs::read(root.join(format!(".manifest-{token}.json"))).expect("read manifest"),
    )
    .expect("decode manifest");
    let session_paths: Vec<&str> = manifest["files"]
        .as_array()
        .expect("manifest files")
        .iter()
        .filter_map(|entry| entry["request_path"].as_str())
        .filter(|path| path.starts_with("/diff-session-"))
        .collect();
    assert_eq!(
        session_paths,
        [abandoned_path.as_str(), replacement_path.as_str()]
    );
    let attacker_token = "fedcba9876543210";
    std::fs::write(
        root.join(format!(".manifest-{attacker_token}.json")),
        serde_json::to_vec(&serde_json::json!({
            "token": attacker_token,
            "files": [{
                "request_path": "/viewer.html",
                "file_path": root.join("viewer.html"),
                "mime_type": "text/html"
            }]
        }))
        .expect("encode attacker manifest"),
    )
    .expect("write attacker manifest");
    let attacker_close = serde_json::to_vec(&serde_json::json!({
        "id": "attacker-close",
        "version": 1,
        "method": "sessionClose",
        "params": {"sessionId": abandoned_session, "capabilityToken": attacker_token}
    }))
    .expect("encode attacker close");
    assert!(
        run_stdio_rpc_in_root(&attacker_close, root)
            .status
            .success()
    );
    assert!(root.join(abandoned_path.trim_start_matches('/')).exists());
    close_session(root, token, &replacement_session, &replacement_path);
    assert!(root.join(abandoned_path.trim_start_matches('/')).exists());
    close_session(root, token, &abandoned_session, &abandoned_path);
}

fn assert_session_matches_git(
    root: &Path,
    repo: &Path,
    token: &str,
    source: &serde_json::Value,
    git_arguments: &[&str],
) {
    let (session_id, request_path) =
        open_session_matches_git(root, repo, token, source, git_arguments);
    close_session(root, token, &session_id, &request_path);
}

fn open_session_matches_git(
    root: &Path,
    repo: &Path,
    token: &str,
    source: &serde_json::Value,
    git_arguments: &[&str],
) -> (String, String) {
    let requested_session_id = uuid::Uuid::new_v4().to_string();
    let request = serde_json::to_vec(&serde_json::json!({
        "id": "open-session",
        "version": 1,
        "method": "sessionOpen",
        "params": {
            "source": source,
            "capabilityToken": token,
            "sessionId": requested_session_id,
        }
    }))
    .expect("encode request");
    let output = run_stdio_rpc_in_root(&request, root);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let response: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("decode response");
    assert_eq!(response["result"]["type"], "sessionOpened", "{response}");
    if source["kind"] == "branch" && source.get("baseRef").is_none() {
        assert_eq!(response["result"]["value"]["source"]["baseRef"], "HEAD");
    }
    let session_id = response["result"]["value"]["sessionId"]
        .as_str()
        .expect("session id")
        .to_owned();
    assert_eq!(session_id, requested_session_id);
    let id = response["result"]["value"]["patch"]["id"]
        .as_str()
        .expect("patch id");
    assert!(id.starts_with(&format!("cmux-diff-viewer://{token}/diff-session-")));
    let request_path = id.split_once(token).expect("token in id").1.to_owned();
    let generated = std::fs::read(root.join(request_path.trim_start_matches('/')))
        .expect("read generated patch");
    let expected = Command::new("/usr/bin/git")
        .arg("-C")
        .arg(repo)
        .args(git_arguments)
        .output()
        .expect("run expected git");
    assert!(expected.status.success());
    assert_eq!(generated, expected.stdout);

    (session_id, request_path)
}

fn close_session(root: &Path, token: &str, session_id: &str, request_path: &str) {
    let close = serde_json::to_vec(&serde_json::json!({
        "id": "close-session",
        "version": 1,
        "method": "sessionClose",
        "params": {"sessionId": session_id, "capabilityToken": token}
    }))
    .expect("encode close request");
    let close_output = run_stdio_rpc_in_root(&close, root);
    assert!(close_output.status.success());
    let close_response: serde_json::Value =
        serde_json::from_slice(&close_output.stdout).expect("decode close response");
    assert_eq!(close_response["result"]["type"], "sessionClosed");
    assert!(!root.join(request_path.trim_start_matches('/')).exists());
}

fn run_git(repo: &Path, arguments: &[&str]) {
    let output = Command::new("/usr/bin/git")
        .arg("-C")
        .arg(repo)
        .args(arguments)
        .output()
        .expect("run git");
    assert!(
        output.status.success(),
        "git failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn serves_only_manifest_allowlisted_files() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let root = std::env::temp_dir().join(format!(
        "cmux-diff-sidecar-test-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    std::fs::create_dir_all(&root).expect("create root");
    #[cfg(unix)]
    {
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))
            .expect("secure root permissions");
    }
    let token = "0123456789abcdef";
    let group = "short-group";
    let patch_path = root.join("sample.patch");
    let generated_path = root.join("generated.html");
    std::fs::write(&patch_path, b"diff --git a/a b/a\n").expect("write patch");
    std::fs::write(&generated_path, b"<!doctype html>").expect("write generated page");
    let manifest = serde_json::json!({
        "token": token,
        "files": [
            {
                "request_path": "/sample.patch",
                "file_path": patch_path,
                "mime_type": "text/x-diff"
            },
            {
                "request_path": "/generated.html",
                "file_path": generated_path,
                "mime_type": "text/html"
            }
        ]
    });
    std::fs::write(
        root.join(format!(".manifest-{token}.json")),
        serde_json::to_vec(&manifest).expect("encode manifest"),
    )
    .expect("write manifest");
    let branch_session = serde_json::json!({
        "token": token,
        "groupID": group,
        "allowedRepoRoots": [&root]
    });
    std::fs::write(
        root.join(format!(".branch-session-{group}.json")),
        serde_json::to_vec(&branch_session).expect("encode branch session"),
    )
    .expect("write branch session");

    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-diff-sidecar"))
        .arg("serve")
        .arg("--root")
        .arg(&root)
        .arg("--cmux")
        .arg(env!("CARGO_BIN_EXE_diff-sidecar-test-host"))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("start sidecar");
    let stdout = child.stdout.take().expect("sidecar stdout");
    let mut reader = BufReader::new(stdout);
    let mut port = String::new();
    reader.read_line(&mut port).expect("read port");
    let port = port.trim().parse::<u16>().expect("valid port");
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    runtime.block_on(async {
        let client = reqwest::Client::new();
        verify_resources(&client, port, token, &root).await;
        verify_rpc(&client, port, token, group, &root).await;
        verify_websocket(port).await;
    });
    let _ = child.kill();
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(root);
}

async fn verify_resources(client: &reqwest::Client, port: u16, token: &str, root: &Path) {
    let health = client
        .get(format!(
            "http://127.0.0.1:{port}/__cmux_diff_viewer_healthz"
        ))
        .send()
        .await
        .expect("health request");
    assert_eq!(health.status(), reqwest::StatusCode::OK);
    assert_eq!(
        health.text().await.expect("health body"),
        cmux_diff_sidecar::health_response()
    );
    let patch = client
        .get(format!("http://127.0.0.1:{port}/{token}/sample.patch"))
        .send()
        .await
        .expect("patch request");
    assert_eq!(patch.status(), reqwest::StatusCode::OK);
    assert_eq!(
        patch.bytes().await.expect("patch body").as_ref(),
        b"diff --git a/a b/a\n"
    );
    let denied = client
        .get(format!("http://127.0.0.1:{port}/{token}/not-allowed.patch"))
        .send()
        .await
        .expect("denied request");
    assert_eq!(denied.status(), reqwest::StatusCode::NOT_FOUND);

    let second_path = root.join("second.patch");
    tokio::fs::write(&second_path, b"diff --git a/b b/b\n")
        .await
        .expect("write second patch");
    let refreshed_manifest = serde_json::json!({
        "token": token,
        "files": [
            {
                "request_path": "/sample.patch",
                "file_path": root.join("sample.patch"),
                "mime_type": "text/x-diff"
            },
            {
                "request_path": "/second.patch",
                "file_path": second_path,
                "mime_type": "text/x-diff"
            },
            {
                "request_path": "/generated.html",
                "file_path": root.join("generated.html"),
                "mime_type": "text/html"
            }
        ]
    });
    tokio::fs::write(
        root.join(format!(".manifest-{token}.json")),
        serde_json::to_vec(&refreshed_manifest).expect("encode refreshed manifest"),
    )
    .await
    .expect("refresh manifest");
    let refreshed = client
        .get(format!("http://127.0.0.1:{port}/{token}/second.patch"))
        .send()
        .await
        .expect("refreshed manifest request");
    assert_eq!(refreshed.status(), reqwest::StatusCode::OK);
}

async fn verify_rpc(client: &reqwest::Client, port: u16, token: &str, group: &str, root: &Path) {
    let endpoint = format!("http://127.0.0.1:{port}/__cmux_diff_rpc");
    let origin = format!("http://127.0.0.1:{port}");
    let branch_request = serde_json::json!({
        "id": "branches",
        "version": 1,
        "method": "branchList",
        "params": {
            "repoRoot": root,
            "capabilityToken": token,
            "selectedBase": "main"
        }
    });
    let branches = client
        .post(&endpoint)
        .header(reqwest::header::ORIGIN, &origin)
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .body(branch_request.to_string())
        .send()
        .await
        .expect("branch list request");
    let branch_bytes = branches.bytes().await.expect("branch list response");
    let branches: serde_json::Value =
        serde_json::from_slice(&branch_bytes).expect("branch list JSON");
    assert_eq!(branches["result"]["type"], "branches");
    assert_eq!(
        branches["result"]["value"]["groups"][0]["rows"][0]["ref"],
        "HEAD"
    );

    let unauthorized_request = serde_json::json!({
        "id": "unauthorized",
        "version": 1,
        "method": "branchList",
        "params": {
            "repoRoot": root,
            "capabilityToken": "fedcba9876543210",
            "selectedBase": "main"
        }
    });
    let unauthorized: serde_json::Value = client
        .post(&endpoint)
        .header(reqwest::header::ORIGIN, &origin)
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .body(unauthorized_request.to_string())
        .send()
        .await
        .expect("unauthorized request")
        .bytes()
        .await
        .map(|bytes| serde_json::from_slice(&bytes).expect("unauthorized response JSON"))
        .expect("unauthorized response bytes");
    assert_eq!(unauthorized["error"]["code"], "branchListFailed");

    // Working-tree writes never run on the loopback development transport,
    // even with a token that is otherwise authorized for the repository.
    let write_request = serde_json::json!({
        "id": "http-write",
        "version": 1,
        "method": "worktreeStageFile",
        "params": {
            "sessionId": uuid::Uuid::new_v4().to_string(),
            "capabilityToken": token,
            "source": {"kind": "unstaged", "repoRoot": root},
            "path": "sample.patch"
        }
    });
    let rejected_write: serde_json::Value = client
        .post(&endpoint)
        .header(reqwest::header::ORIGIN, &origin)
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .body(write_request.to_string())
        .send()
        .await
        .expect("http write request")
        .bytes()
        .await
        .map(|bytes| serde_json::from_slice(&bytes).expect("http write response JSON"))
        .expect("http write response bytes");
    assert_eq!(rejected_write["id"], "http-write");
    assert_eq!(rejected_write["error"]["code"], "notAllowed");

    let untrusted = client
        .post(&endpoint)
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .body(branch_request.to_string())
        .send()
        .await
        .expect("untrusted request");
    assert_eq!(untrusted.status(), reqwest::StatusCode::NOT_FOUND);

    verify_branch_change(client, &endpoint, &origin, token, group, root).await;
}

async fn verify_branch_change(
    client: &reqwest::Client,
    endpoint: &str,
    origin: &str,
    token: &str,
    group: &str,
    root: &Path,
) {
    let branch_change = serde_json::json!({
        "id": "branch-change",
        "version": 1,
        "method": "branchChange",
        "params": {
            "groupId": group,
            "repoRoot": root,
            "baseRef": "main",
            "capabilityToken": token
        }
    });
    let changed: serde_json::Value = client
        .post(endpoint)
        .header(reqwest::header::ORIGIN, origin)
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .body(branch_change.to_string())
        .send()
        .await
        .expect("branch change request")
        .bytes()
        .await
        .map(|bytes| serde_json::from_slice(&bytes).expect("branch change response JSON"))
        .expect("branch change response bytes");
    assert_eq!(changed["result"]["type"], "navigation");

    let malformed_change = serde_json::json!({
        "id": "malformed-branch-change",
        "version": 1,
        "method": "branchChange",
        "params": {
            "groupId": group,
            "repoRoot": root,
            "baseRef": "malformed",
            "capabilityToken": token
        }
    });
    let malformed: serde_json::Value = client
        .post(endpoint)
        .header(reqwest::header::ORIGIN, origin)
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .body(malformed_change.to_string())
        .send()
        .await
        .expect("malformed branch change request")
        .bytes()
        .await
        .map(|bytes| serde_json::from_slice(&bytes).expect("malformed response JSON"))
        .expect("malformed response bytes");
    assert_eq!(malformed["error"]["code"], "branchChangeFailed");
}

async fn verify_websocket(port: u16) {
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;

    let mut request = format!("ws://127.0.0.1:{port}/__cmux_diff_ws")
        .into_client_request()
        .expect("WebSocket request");
    request.headers_mut().insert(
        "origin",
        format!("http://127.0.0.1:{port}")
            .parse()
            .expect("origin header"),
    );
    let (mut socket, _) = tokio_tungstenite::connect_async(request)
        .await
        .expect("WebSocket connect");
    socket
        .send(tokio_tungstenite::tungstenite::Message::Text(
            r#"{"id":"hello","version":1,"method":"protocolHandshake"}"#.into(),
        ))
        .await
        .expect("WebSocket handshake request");
    let response = socket
        .next()
        .await
        .expect("WebSocket response")
        .expect("valid WebSocket response")
        .into_text()
        .expect("text response");
    let response: serde_json::Value = serde_json::from_str(&response).expect("JSON response");
    assert_eq!(response["id"], "hello");
    assert_eq!(response["result"]["value"]["protocolVersion"], 1);

    socket
        .send(tokio_tungstenite::tungstenite::Message::Text(
            serde_json::json!({
                "id": "ws-write",
                "version": 1,
                "method": "worktreeCommit",
                "params": {
                    "sessionId": uuid::Uuid::new_v4().to_string(),
                    "capabilityToken": "0123456789abcdef",
                    "source": {"kind": "staged", "repoRoot": "/tmp"},
                    "message": "not over this transport"
                }
            })
            .to_string()
            .into(),
        ))
        .await
        .expect("WebSocket write request");
    let rejected = socket
        .next()
        .await
        .expect("WebSocket write response")
        .expect("valid WebSocket write response")
        .into_text()
        .expect("text write response");
    let rejected: serde_json::Value = serde_json::from_str(&rejected).expect("JSON write response");
    assert_eq!(rejected["id"], "ws-write");
    assert_eq!(rejected["error"]["code"], "notAllowed");

    socket
        .send(tokio_tungstenite::tungstenite::Message::Text(
            "not-json".into(),
        ))
        .await
        .expect("invalid WebSocket request");
    let close = socket
        .next()
        .await
        .expect("WebSocket close")
        .expect("valid WebSocket close");
    assert!(close.is_close());
}

#[test]
// One repository fixture walks every write command in sequence; the shared
// state between steps is the point of the test.
#[allow(clippy::too_many_lines)]
fn rpc_worktree_writes_mutate_the_repository_like_git() {
    let root = std::env::temp_dir().join(format!(
        "cmux-diff-sidecar-worktree-test-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    let repo = root.join("repo");
    let other_repo = root.join("other");
    for directory in [&repo, &other_repo] {
        std::fs::create_dir_all(directory).expect("create repo");
        run_git(directory, &["init", "-q"]);
        run_git(directory, &["config", "user.name", "cmux tests"]);
        run_git(directory, &["config", "user.email", "cmux@example.invalid"]);
        run_git(directory, &["config", "commit.gpgsign", "false"]);
    }
    #[cfg(unix)]
    {
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))
            .expect("secure root permissions");
    }
    let mut original = String::new();
    for line in 1..=30 {
        original.push_str("line ");
        original.push_str(&line.to_string());
        original.push('\n');
    }
    std::fs::write(repo.join("story.txt"), &original).expect("write initial file");
    run_git(&repo, &["add", "story.txt"]);
    run_git(&repo, &["commit", "-q", "-m", "initial"]);
    std::fs::write(other_repo.join("other.txt"), "other\n").expect("write other file");
    run_git(&other_repo, &["add", "other.txt"]);
    run_git(&other_repo, &["commit", "-q", "-m", "initial"]);

    let token = "0123456789abcdef";
    let attacker_token = "fedcba9876543210";
    let shell = root.join("viewer.html");
    std::fs::write(&shell, b"<!doctype html>").expect("write shell");
    for (session_token, group, allowed) in [
        (token, "worktree-test", &repo),
        (attacker_token, "worktree-attacker", &other_repo),
    ] {
        std::fs::write(
            root.join(format!(".manifest-{session_token}.json")),
            serde_json::to_vec(&serde_json::json!({
                "token": session_token,
                "files": [{
                    "request_path": "/viewer.html",
                    "file_path": shell,
                    "mime_type": "text/html"
                }]
            }))
            .expect("encode manifest"),
        )
        .expect("write manifest");
        std::fs::write(
            root.join(format!(".branch-session-{group}.json")),
            serde_json::to_vec(&serde_json::json!({
                "token": session_token,
                "groupID": group,
                "allowedRepoRoots": [allowed]
            }))
            .expect("encode session"),
        )
        .expect("write session");
    }
    let unstaged = serde_json::json!({"kind": "unstaged", "repoRoot": repo});
    let staged = serde_json::json!({"kind": "staged", "repoRoot": repo});
    let unstaged_git = ["diff", "--no-ext-diff", "--no-color", "--binary", "--"];
    let staged_git = [
        "diff",
        "--no-ext-diff",
        "--no-color",
        "--binary",
        "--cached",
        "--",
    ];
    let file_params = |session: &str, session_token: &str, source: &serde_json::Value, path| {
        serde_json::json!({
            "sessionId": session,
            "capabilityToken": session_token,
            "source": source,
            "path": path
        })
    };

    // Revert a modified tracked file through an unstaged session, then check
    // every authorization boundary while that session is still open.
    let modified = original.replacen("line 3\n", "line 3 changed\n", 1);
    std::fs::write(repo.join("story.txt"), &modified).expect("modify file");
    let (session, request_path) =
        open_session_matches_git(&root, &repo, token, &unstaged, &unstaged_git);
    let branch = serde_json::json!({"kind": "branch", "repoRoot": repo, "baseRef": "HEAD"});
    let patch = serde_json::json!({"kind": "patch", "path": "/viewer.html"});
    let other = serde_json::json!({"kind": "unstaged", "repoRoot": other_repo});
    for (params, code) in [
        (
            file_params(&session, token, &branch, "story.txt"),
            "notAllowed",
        ),
        (
            file_params(&session, token, &patch, "story.txt"),
            "notAllowed",
        ),
        (
            file_params(&session, attacker_token, &unstaged, "story.txt"),
            "notAllowed",
        ),
        (
            file_params(&session, attacker_token, &other, "other.txt"),
            "notAllowed",
        ),
        (
            file_params(
                &uuid::Uuid::new_v4().to_string(),
                token,
                &unstaged,
                "story.txt",
            ),
            "notAllowed",
        ),
        (
            file_params(&session, token, &unstaged, "../story.txt"),
            "invalidPath",
        ),
        (
            file_params(&session, token, &unstaged, "/etc/passwd"),
            "invalidPath",
        ),
        (
            file_params(&session, token, &unstaged, "a/./story.txt"),
            "invalidPath",
        ),
        (file_params(&session, token, &unstaged, ""), "invalidPath"),
    ] {
        let response = worktree_write(&root, "worktreeRevertFile", &params);
        assert_eq!(response["error"]["code"], code, "{params} -> {response}");
        assert_eq!(
            std::fs::read_to_string(repo.join("story.txt")).expect("read file"),
            modified
        );
    }
    // An untracked path never comes from a `git diff` session, so reverting
    // one is refused instead of cleaned away, on its own or as the rename
    // origin of a tracked file.
    std::fs::write(repo.join("untracked.txt"), "keep me\n").expect("write untracked file");
    let untracked_alone = worktree_write(
        &root,
        "worktreeRevertFile",
        &file_params(&session, token, &unstaged, "untracked.txt"),
    );
    assert_eq!(
        untracked_alone["error"]["code"], "invalidPath",
        "{untracked_alone}"
    );
    let untracked_origin = worktree_write(
        &root,
        "worktreeRevertFile",
        &serde_json::json!({
            "sessionId": session,
            "capabilityToken": token,
            "source": unstaged,
            "path": "story.txt",
            "previousPath": "untracked.txt"
        }),
    );
    assert_eq!(
        untracked_origin["error"]["code"], "invalidPath",
        "{untracked_origin}"
    );
    assert_eq!(
        std::fs::read_to_string(repo.join("untracked.txt")).expect("untracked file survives"),
        "keep me\n"
    );
    assert_eq!(
        std::fs::read_to_string(repo.join("story.txt")).expect("read file"),
        modified
    );
    std::fs::remove_file(repo.join("untracked.txt")).expect("remove untracked file");
    let commit_on_unstaged = worktree_write(
        &root,
        "worktreeCommit",
        &serde_json::json!({
            "sessionId": session,
            "capabilityToken": token,
            "source": unstaged,
            "message": "never"
        }),
    );
    assert_eq!(commit_on_unstaged["error"]["code"], "notAllowed");
    let reverted = worktree_write(
        &root,
        "worktreeRevertFile",
        &file_params(&session, token, &unstaged, "story.txt"),
    );
    assert_eq!(reverted["result"]["type"], "worktreeMutated", "{reverted}");
    assert_eq!(reverted["result"]["value"]["source"], unstaged);
    assert_eq!(
        std::fs::read_to_string(repo.join("story.txt")).expect("read reverted file"),
        original
    );
    close_session(&root, token, &session, &request_path);
    std::fs::write(repo.join("story.txt"), &modified).expect("modify file again");
    let closed = worktree_write(
        &root,
        "worktreeRevertFile",
        &file_params(&session, token, &unstaged, "story.txt"),
    );
    assert_eq!(closed["error"]["code"], "notAllowed");

    // Stage and unstage one file.
    let (session, request_path) =
        open_session_matches_git(&root, &repo, token, &unstaged, &unstaged_git);
    let staged_response = worktree_write(
        &root,
        "worktreeStageFile",
        &file_params(&session, token, &unstaged, "story.txt"),
    );
    assert_eq!(staged_response["result"]["type"], "worktreeMutated");
    assert_eq!(
        git_stdout(&repo, &["diff", "--cached", "--name-only"]),
        "story.txt\n"
    );
    let unstaged_response = worktree_write(
        &root,
        "worktreeUnstageFile",
        &file_params(&session, token, &unstaged, "story.txt"),
    );
    assert_eq!(unstaged_response["result"]["type"], "worktreeMutated");
    assert_eq!(git_stdout(&repo, &["diff", "--cached", "--name-only"]), "");
    close_session(&root, token, &session, &request_path);

    // Revert one of two hunks, then observe the stale header afterwards.
    let two_hunks = modified.replacen("line 27\n", "line 27 changed\n", 1);
    std::fs::write(repo.join("story.txt"), &two_hunks).expect("write two hunks");
    let (session, request_path) =
        open_session_matches_git(&root, &repo, token, &unstaged, &unstaged_git);
    let hunks = hunk_refs(&git_stdout(&repo, &["diff", "--", "story.txt"]));
    assert_eq!(hunks.len(), 2, "{hunks:?}");
    let hunk_params = |session: &str, source: &serde_json::Value, hunk: &serde_json::Value| {
        serde_json::json!({
            "sessionId": session,
            "capabilityToken": token,
            "source": source,
            "path": "story.txt",
            "hunk": hunk
        })
    };
    let hunk_reverted = worktree_write(
        &root,
        "worktreeRevertHunk",
        &hunk_params(&session, &unstaged, &hunks[1]),
    );
    assert_eq!(
        hunk_reverted["result"]["type"], "worktreeMutated",
        "{hunk_reverted}"
    );
    assert_eq!(
        std::fs::read_to_string(repo.join("story.txt")).expect("read after hunk revert"),
        modified
    );
    let stale = worktree_write(
        &root,
        "worktreeRevertHunk",
        &hunk_params(&session, &unstaged, &hunks[1]),
    );
    assert_eq!(stale["error"]["code"], "staleHunk", "{stale}");
    close_session(&root, token, &session, &request_path);

    // A staged hunk revert discards the change from both the index and the
    // working tree.
    run_git(&repo, &["add", "story.txt"]);
    let (session, request_path) =
        open_session_matches_git(&root, &repo, token, &staged, &staged_git);
    let staged_hunks = hunk_refs(&git_stdout(&repo, &["diff", "--cached", "--", "story.txt"]));
    assert_eq!(staged_hunks.len(), 1, "{staged_hunks:?}");
    let staged_revert = worktree_write(
        &root,
        "worktreeRevertHunk",
        &hunk_params(&session, &staged, &staged_hunks[0]),
    );
    assert_eq!(
        staged_revert["result"]["type"], "worktreeMutated",
        "{staged_revert}"
    );
    assert_eq!(
        std::fs::read_to_string(repo.join("story.txt")).expect("read after staged revert"),
        original
    );
    assert_eq!(git_stdout(&repo, &["status", "--porcelain"]), "");
    close_session(&root, token, &session, &request_path);

    // Reverting a file staged as new removes it entirely.
    std::fs::write(repo.join("new.txt"), "brand new\n").expect("write new file");
    run_git(&repo, &["add", "new.txt"]);
    let (session, request_path) =
        open_session_matches_git(&root, &repo, token, &staged, &staged_git);
    let new_reverted = worktree_write(
        &root,
        "worktreeRevertFile",
        &file_params(&session, token, &staged, "new.txt"),
    );
    assert_eq!(
        new_reverted["result"]["type"], "worktreeMutated",
        "{new_reverted}"
    );
    assert!(!repo.join("new.txt").exists());
    assert_eq!(git_stdout(&repo, &["status", "--porcelain"]), "");
    close_session(&root, token, &session, &request_path);

    // A staged rename with edits keeps its hunks addressable when the request
    // names the rename origin, and reverting one hunk keeps the rename. The
    // user's `diff.noprefix` must not leak into the patch the sidecar applies.
    run_git(&repo, &["config", "diff.noprefix", "true"]);
    run_git(&repo, &["mv", "story.txt", "renamed.txt"]);
    std::fs::write(repo.join("renamed.txt"), &two_hunks).expect("edit renamed file");
    run_git(&repo, &["add", "renamed.txt"]);
    let (session, request_path) =
        open_session_matches_git(&root, &repo, token, &staged, &staged_git);
    let rename_hunks = hunk_refs(&git_stdout(
        &repo,
        &["diff", "--cached", "--", "renamed.txt", "story.txt"],
    ));
    assert_eq!(rename_hunks.len(), 2, "{rename_hunks:?}");
    let rename_hunk_params = |hunk: &serde_json::Value, with_origin: bool| {
        let mut params = serde_json::json!({
            "sessionId": session,
            "capabilityToken": token,
            "source": staged,
            "path": "renamed.txt",
            "hunk": hunk
        });
        if with_origin {
            params["previousPath"] = serde_json::json!("story.txt");
        }
        params
    };
    let without_origin = worktree_write(
        &root,
        "worktreeRevertHunk",
        &rename_hunk_params(&rename_hunks[1], false),
    );
    assert_eq!(
        without_origin["error"]["code"], "staleHunk",
        "{without_origin}"
    );
    let rename_hunk_reverted = worktree_write(
        &root,
        "worktreeRevertHunk",
        &rename_hunk_params(&rename_hunks[1], true),
    );
    assert_eq!(
        rename_hunk_reverted["result"]["type"], "worktreeMutated",
        "{rename_hunk_reverted}"
    );
    assert_eq!(
        git_stdout(&repo, &["status", "--porcelain"]),
        "R  story.txt -> renamed.txt\n"
    );
    assert_eq!(
        std::fs::read_to_string(repo.join("renamed.txt")).expect("read renamed file"),
        modified
    );
    close_session(&root, token, &session, &request_path);
    run_git(&repo, &["config", "--unset", "diff.noprefix"]);
    run_git(&repo, &["reset", "-q", "--hard", "HEAD"]);
    assert_eq!(git_stdout(&repo, &["status", "--porcelain"]), "");

    // Commit the index through a staged session.

    std::fs::write(repo.join("story.txt"), &modified).expect("modify for commit");
    run_git(&repo, &["add", "story.txt"]);
    let (session, request_path) =
        open_session_matches_git(&root, &repo, token, &staged, &staged_git);
    let commit_params = |message: &str| {
        serde_json::json!({
            "sessionId": session,
            "capabilityToken": token,
            "source": staged,
            "message": message
        })
    };
    let empty_message = worktree_write(&root, "worktreeCommit", &commit_params("   \n"));
    assert_eq!(empty_message["error"]["code"], "invalidMessage");
    let committed = worktree_write(
        &root,
        "worktreeCommit",
        &commit_params("  Change line three\n\nBody text\n"),
    );
    assert_eq!(committed["result"]["type"], "committed", "{committed}");
    assert_eq!(
        committed["result"]["value"]["commit"],
        git_stdout(&repo, &["rev-parse", "HEAD"]).trim()
    );
    assert_eq!(
        git_stdout(&repo, &["log", "-1", "--format=%s"]),
        "Change line three\n"
    );
    assert_eq!(git_stdout(&repo, &["status", "--porcelain"]), "");
    let nothing = worktree_write(&root, "worktreeCommit", &commit_params("again"));
    assert_eq!(nothing["error"]["code"], "nothingToCommit");
    close_session(&root, token, &session, &request_path);

    assert!(!root.join(".server.json").exists());
    let _ = std::fs::remove_dir_all(root);
}

/// Authorizes `token` for `allowed` repositories under `root`: a manifest
/// carrying the viewer shell and a branch-session allow-list named `group`.
fn authorize_repos(root: &Path, token: &str, group: &str, allowed: &[&Path]) {
    let shell = root.join("viewer.html");
    std::fs::write(&shell, b"<!doctype html>").expect("write shell");
    std::fs::write(
        root.join(format!(".manifest-{token}.json")),
        serde_json::to_vec(&serde_json::json!({
            "token": token,
            "files": [{
                "request_path": "/viewer.html",
                "file_path": shell,
                "mime_type": "text/html"
            }]
        }))
        .expect("encode manifest"),
    )
    .expect("write manifest");
    std::fs::write(
        root.join(format!(".branch-session-{group}.json")),
        serde_json::to_vec(&serde_json::json!({
            "token": token,
            "groupID": group,
            "allowedRepoRoots": allowed
        }))
        .expect("encode session"),
    )
    .expect("write session");
}

fn init_repo(directory: &Path) {
    std::fs::create_dir_all(directory).expect("create repo");
    run_git(directory, &["init", "-q"]);
    run_git(directory, &["config", "user.name", "cmux tests"]);
    run_git(directory, &["config", "user.email", "cmux@example.invalid"]);
    run_git(directory, &["config", "commit.gpgsign", "false"]);
    run_git(directory, &["config", "core.hooksPath", ".git/hooks"]);
}

const UNSTAGED_GIT: [&str; 5] = ["diff", "--no-ext-diff", "--no-color", "--binary", "--"];
const STAGED_GIT: [&str; 6] = [
    "diff",
    "--no-ext-diff",
    "--no-color",
    "--binary",
    "--cached",
    "--",
];

fn write_params(
    session: &str,
    token: &str,
    source: &serde_json::Value,
    path: &str,
) -> serde_json::Value {
    serde_json::json!({
        "sessionId": session,
        "capabilityToken": token,
        "source": source,
        "path": path
    })
}

fn hunk_params(
    session: &str,
    token: &str,
    source: &serde_json::Value,
    path: &str,
    hunk: &serde_json::Value,
) -> serde_json::Value {
    let mut params = write_params(session, token, source, path);
    params["hunk"] = hunk.clone();
    params
}

fn numbered_lines(count: u32) -> String {
    let mut lines = String::new();
    for line in 1..=count {
        lines.push_str("line ");
        lines.push_str(&line.to_string());
        lines.push('\n');
    }
    lines
}

#[test]
// One fixture per concern, all sharing the authorization setup; the
// sequence within each block is the behavior under test.
#[allow(clippy::too_many_lines)]
fn rpc_worktree_writes_bind_sessions_and_report_partial_states() {
    let root = std::env::temp_dir().join(format!(
        "cmux-diff-sidecar-worktree-edge-test-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    let repo = root.join("repo");
    let nested = repo.join("nested");
    let unborn = root.join("unborn");
    init_repo(&repo);
    init_repo(&unborn);
    std::fs::create_dir_all(&nested).expect("create nested directory");
    #[cfg(unix)]
    {
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))
            .expect("secure root permissions");
    }
    let token = "0123456789abcdef";
    authorize_repos(&root, token, "worktree-edge", &[&repo, &nested, &unborn]);
    let original = numbered_lines(30);
    std::fs::write(repo.join("story.txt"), &original).expect("write story");
    std::fs::create_dir_all(repo.join("src")).expect("create src");
    std::fs::write(repo.join("src/a.txt"), "a\n").expect("write src/a.txt");
    std::fs::write(repo.join("src/b.txt"), "b\n").expect("write src/b.txt");
    std::fs::write(nested.join("inner.txt"), "inner\n").expect("write nested file");
    std::fs::write(repo.join("-dash.txt"), "dash\n").expect("write dash file");
    let weird = "we\"ird\ttab \u{e9}.txt";
    std::fs::write(repo.join(weird), &original).expect("write weird file");
    run_git(&repo, &["add", "--", "."]);
    run_git(&repo, &["commit", "-q", "-m", "initial"]);
    run_git(&repo, &["branch", "base"]);
    std::fs::write(
        repo.join("story.txt"),
        original.replacen("line 1\n", "line 1 committed\n", 1),
    )
    .expect("commit a change");
    run_git(&repo, &["commit", "-q", "-a", "-m", "second"]);
    let committed = std::fs::read_to_string(repo.join("story.txt")).expect("read committed");
    let unstaged = serde_json::json!({"kind": "unstaged", "repoRoot": repo});
    let staged = serde_json::json!({"kind": "staged", "repoRoot": repo});
    let branch = serde_json::json!({"kind": "branch", "repoRoot": repo, "baseRef": "base"});
    let staged_edit = committed.replacen("line 3\n", "line 3 changed\n", 1);
    let both_edits = staged_edit.replacen("line 27\n", "line 27 changed\n", 1);

    // A session authorizes writes only for the source kind it was opened
    // with: neither a branch session nor a staged session can issue an
    // unstaged write, even though both are bound to this repository.
    std::fs::write(repo.join("story.txt"), &staged_edit).expect("stage an edit");
    run_git(&repo, &["add", "story.txt"]);
    std::fs::write(repo.join("story.txt"), &both_edits).expect("add an unstaged edit");
    let (branch_session, branch_path) = open_session_matches_git(
        &root,
        &repo,
        token,
        &branch,
        &[
            "diff",
            "--no-ext-diff",
            "--no-color",
            "--binary",
            "base",
            "--",
        ],
    );
    let (staged_session, staged_path) =
        open_session_matches_git(&root, &repo, token, &staged, &STAGED_GIT);
    for session in [&branch_session, &staged_session] {
        let response = worktree_write(
            &root,
            "worktreeStageFile",
            &write_params(session, token, &unstaged, "story.txt"),
        );
        assert_eq!(response["error"]["code"], "notAllowed", "{response}");
    }
    let cross_kind_revert = worktree_write(
        &root,
        "worktreeRevertFile",
        &write_params(&branch_session, token, &staged, "story.txt"),
    );
    assert_eq!(cross_kind_revert["error"]["code"], "notAllowed");
    assert_eq!(
        std::fs::read_to_string(repo.join("story.txt")).expect("read story"),
        both_edits
    );
    close_session(&root, token, &branch_session, &branch_path);

    // Reverting a staged hunk unstages it and discards it from the working
    // tree while leaving an unrelated unstaged hunk in the same file alone.
    let staged_hunks = hunk_refs(&git_stdout(&repo, &["diff", "--cached", "--", "story.txt"]));
    assert_eq!(staged_hunks.len(), 1, "{staged_hunks:?}");
    let reverted = worktree_write(
        &root,
        "worktreeRevertHunk",
        &hunk_params(
            &staged_session,
            token,
            &staged,
            "story.txt",
            &staged_hunks[0],
        ),
    );
    assert_eq!(reverted["result"]["type"], "worktreeMutated", "{reverted}");
    assert_eq!(git_stdout(&repo, &["diff", "--cached", "--name-only"]), "");
    assert_eq!(
        std::fs::read_to_string(repo.join("story.txt")).expect("read story"),
        committed.replacen("line 27\n", "line 27 changed\n", 1)
    );
    // When the working tree no longer carries the staged hunk, the index
    // part still happens and the split state is reported for a reload.
    std::fs::write(repo.join("story.txt"), &staged_edit).expect("stage an edit");
    run_git(&repo, &["add", "story.txt"]);
    let diverged = committed.replacen("line 3\n", "line 3 different\n", 1);
    std::fs::write(repo.join("story.txt"), &diverged).expect("diverge the working tree");
    let partial = worktree_write(
        &root,
        "worktreeRevertHunk",
        &hunk_params(
            &staged_session,
            token,
            &staged,
            "story.txt",
            &staged_hunks[0],
        ),
    );
    assert_eq!(partial["error"]["code"], "partialRevert", "{partial}");
    assert_eq!(git_stdout(&repo, &["diff", "--cached", "--name-only"]), "");
    assert_eq!(
        std::fs::read_to_string(repo.join("story.txt")).expect("read story"),
        diverged
    );
    // A held index lock makes the index step fail cleanly: `conflict`, and
    // nothing changes.
    run_git(&repo, &["add", "story.txt"]);
    let locked_hunks = hunk_refs(&git_stdout(&repo, &["diff", "--cached", "--", "story.txt"]));
    std::fs::write(repo.join(".git/index.lock"), b"").expect("hold the index lock");
    let conflict = worktree_write(
        &root,
        "worktreeRevertHunk",
        &hunk_params(
            &staged_session,
            token,
            &staged,
            "story.txt",
            &locked_hunks[0],
        ),
    );
    std::fs::remove_file(repo.join(".git/index.lock")).expect("release the index lock");
    assert_eq!(conflict["error"]["code"], "conflict", "{conflict}");
    assert_eq!(
        git_stdout(&repo, &["diff", "--cached", "--name-only"]),
        "story.txt\n"
    );

    // A directory name is never a revertable path: matching is by whole
    // blob, so `src` restores nothing even though HEAD has `src/a.txt`.
    std::fs::write(repo.join("src/a.txt"), "a changed\n").expect("edit src/a.txt");
    std::fs::write(repo.join("src/b.txt"), "b changed\n").expect("edit src/b.txt");
    run_git(&repo, &["add", "src"]);
    let directory = worktree_write(
        &root,
        "worktreeRevertFile",
        &write_params(&staged_session, token, &staged, "src"),
    );
    assert_eq!(directory["error"]["code"], "invalidPath", "{directory}");
    assert_eq!(
        std::fs::read_to_string(repo.join("src/a.txt")).expect("read src/a.txt"),
        "a changed\n"
    );
    assert!(git_stdout(&repo, &["diff", "--cached", "--name-only"]).contains("src/a.txt"));
    close_session(&root, token, &staged_session, &staged_path);
    run_git(&repo, &["reset", "-q", "--hard", "HEAD"]);

    // Staging requires an index entry: an untracked file never shows in an
    // unstaged session, so a request for one comes from the page.
    std::fs::write(repo.join("story.txt"), &staged_edit).expect("edit story");
    std::fs::write(repo.join("untracked.txt"), "secret\n").expect("write untracked");
    let (unstaged_session, unstaged_path) =
        open_session_matches_git(&root, &repo, token, &unstaged, &UNSTAGED_GIT);
    let untracked = worktree_write(
        &root,
        "worktreeStageFile",
        &write_params(&unstaged_session, token, &unstaged, "untracked.txt"),
    );
    assert_eq!(untracked["error"]["code"], "invalidPath", "{untracked}");
    assert_eq!(git_stdout(&repo, &["ls-files", "--", "untracked.txt"]), "");
    std::fs::remove_file(repo.join("untracked.txt")).expect("remove untracked");

    // Unusual names round-trip end to end: a tab, a quote, and a non-ASCII
    // character (which Git quotes in headers), and a name starting with `-`.
    let weird_edit = original.replacen("line 5\n", "line 5 changed\n", 1);
    std::fs::write(repo.join(weird), &weird_edit).expect("edit weird file");
    std::fs::write(repo.join("-dash.txt"), "dash changed\n").expect("edit dash file");
    let weird_hunks = hunk_refs(&git_stdout(&repo, &["diff", "--", weird]));
    assert_eq!(weird_hunks.len(), 1, "{weird_hunks:?}");
    let weird_hunk = worktree_write(
        &root,
        "worktreeRevertHunk",
        &hunk_params(&unstaged_session, token, &unstaged, weird, &weird_hunks[0]),
    );
    assert_eq!(
        weird_hunk["result"]["type"], "worktreeMutated",
        "{weird_hunk}"
    );
    assert_eq!(
        std::fs::read_to_string(repo.join(weird)).expect("read weird file"),
        original
    );
    std::fs::write(repo.join(weird), &weird_edit).expect("edit weird file again");
    for path in [weird, "-dash.txt"] {
        let staged_file = worktree_write(
            &root,
            "worktreeStageFile",
            &write_params(&unstaged_session, token, &unstaged, path),
        );
        assert_eq!(
            staged_file["result"]["type"], "worktreeMutated",
            "{staged_file}"
        );
    }
    assert_eq!(
        git_stdout(&repo, &["diff", "--cached", "--name-only", "-z"]),
        format!("-dash.txt\0{weird}\0")
    );
    for path in [weird, "-dash.txt"] {
        let unstaged_file = worktree_write(
            &root,
            "worktreeUnstageFile",
            &write_params(&unstaged_session, token, &unstaged, path),
        );
        assert_eq!(
            unstaged_file["result"]["type"], "worktreeMutated",
            "{unstaged_file}"
        );
        let reverted_file = worktree_write(
            &root,
            "worktreeRevertFile",
            &write_params(&unstaged_session, token, &unstaged, path),
        );
        assert_eq!(
            reverted_file["result"]["type"], "worktreeMutated",
            "{reverted_file}"
        );
    }
    assert_eq!(
        std::fs::read_to_string(repo.join("-dash.txt")).expect("read dash file"),
        "dash\n"
    );
    assert_eq!(
        std::fs::read_to_string(repo.join(weird)).expect("read weird file"),
        original
    );
    close_session(&root, token, &unstaged_session, &unstaged_path);

    // A session opened on a nested directory of the working tree is not a
    // write target: diff paths are top-level relative.
    std::fs::write(nested.join("inner.txt"), "inner changed\n").expect("edit nested file");
    let nested_source = serde_json::json!({"kind": "unstaged", "repoRoot": nested});
    let (nested_session, nested_path) =
        open_session_matches_git(&root, &nested, token, &nested_source, &UNSTAGED_GIT);
    let nested_write = worktree_write(
        &root,
        "worktreeRevertFile",
        &write_params(&nested_session, token, &nested_source, "nested/inner.txt"),
    );
    assert_eq!(
        nested_write["error"]["code"], "notAllowed",
        "{nested_write}"
    );
    assert_eq!(
        std::fs::read_to_string(nested.join("inner.txt")).expect("read nested file"),
        "inner changed\n"
    );
    close_session(&root, token, &nested_session, &nested_path);
    run_git(&repo, &["reset", "-q", "--hard", "HEAD"]);

    // A failing hook is reported with its verdict, bounded, and HEAD stays.
    std::fs::write(repo.join("story.txt"), &staged_edit).expect("edit story");
    run_git(&repo, &["add", "story.txt"]);
    let hook = repo.join(".git/hooks/pre-commit");
    std::fs::create_dir_all(repo.join(".git/hooks")).expect("create hooks directory");
    std::fs::write(
        &hook,
        format!(
            "#!/bin/sh\necho checking >&2\necho \"hook says no {}\" >&2\nexit 1\n",
            "x".repeat(400)
        ),
    )
    .expect("write hook");
    #[cfg(unix)]
    std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).expect("chmod hook");
    let head_before = git_stdout(&repo, &["rev-parse", "HEAD"]);
    let (hook_session, hook_path) =
        open_session_matches_git(&root, &repo, token, &staged, &STAGED_GIT);
    let refused = worktree_write(
        &root,
        "worktreeCommit",
        &serde_json::json!({
            "sessionId": hook_session,
            "capabilityToken": token,
            "source": staged,
            "message": "blocked"
        }),
    );
    assert_eq!(refused["error"]["code"], "commitFailed", "{refused}");
    let message = refused["error"]["message"].as_str().expect("message");
    assert!(message.contains("hook says no"), "{message}");
    assert!(!message.contains("checking"), "{message}");
    assert!(message.len() < 300, "{message}");
    assert_eq!(git_stdout(&repo, &["rev-parse", "HEAD"]), head_before);
    std::fs::remove_file(&hook).expect("remove hook");
    close_session(&root, token, &hook_session, &hook_path);

    // An unborn branch: a file staged as new can be reverted (removed), and
    // the first commit works without a parent.
    let unborn_staged = serde_json::json!({"kind": "staged", "repoRoot": unborn});
    std::fs::write(unborn.join("first.txt"), "first\n").expect("write first file");
    run_git(&unborn, &["add", "first.txt"]);
    let (unborn_session, unborn_path) =
        open_session_matches_git(&root, &unborn, token, &unborn_staged, &STAGED_GIT);
    let removed = worktree_write(
        &root,
        "worktreeRevertFile",
        &write_params(&unborn_session, token, &unborn_staged, "first.txt"),
    );
    assert_eq!(removed["result"]["type"], "worktreeMutated", "{removed}");
    assert!(!unborn.join("first.txt").exists());
    assert_eq!(git_stdout(&unborn, &["status", "--porcelain"]), "");
    std::fs::write(unborn.join("first.txt"), "first\n").expect("write first file again");
    run_git(&unborn, &["add", "first.txt"]);
    let first_commit = worktree_write(
        &root,
        "worktreeCommit",
        &serde_json::json!({
            "sessionId": unborn_session,
            "capabilityToken": token,
            "source": unborn_staged,
            "message": "Initial commit"
        }),
    );
    assert_eq!(
        first_commit["result"]["type"], "committed",
        "{first_commit}"
    );
    assert_eq!(
        first_commit["result"]["value"]["commit"],
        git_stdout(&unborn, &["rev-parse", "HEAD"]).trim()
    );
    assert_eq!(
        git_stdout(&unborn, &["log", "--format=%s"]),
        "Initial commit\n"
    );
    close_session(&root, token, &unborn_session, &unborn_path);

    assert!(!root.join(".server.json").exists());
    let _ = std::fs::remove_dir_all(root);
}

fn worktree_write(root: &Path, method: &str, params: &serde_json::Value) -> serde_json::Value {
    let request = serde_json::to_vec(&serde_json::json!({
        "id": method,
        "version": 1,
        "method": method,
        "params": params
    }))
    .expect("encode write request");
    let output = run_stdio_rpc_in_root(&request, root);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let response: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("decode write response");
    assert_eq!(response["id"], method);
    response
}

fn git_stdout(repo: &Path, arguments: &[&str]) -> String {
    let output = Command::new("/usr/bin/git")
        .arg("-C")
        .arg(repo)
        .args(arguments)
        .output()
        .expect("run git");
    assert!(
        output.status.success(),
        "git failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).expect("utf8 git output")
}

fn hunk_refs(diff: &str) -> Vec<serde_json::Value> {
    diff.lines()
        .filter_map(|line| {
            let rest = line.strip_prefix("@@ -")?;
            let (old, rest) = rest.split_once(" +")?;
            let (new, _) = rest.split_once(" @@")?;
            let range = |value: &str| -> Option<(u32, u32)> {
                match value.split_once(',') {
                    Some((start, count)) => Some((start.parse().ok()?, count.parse().ok()?)),
                    None => Some((value.parse().ok()?, 1)),
                }
            };
            let (old_start, old_count) = range(old)?;
            let (new_start, new_count) = range(new)?;
            Some(serde_json::json!({
                "oldStart": old_start,
                "oldCount": old_count,
                "newStart": new_start,
                "newCount": new_count
            }))
        })
        .collect()
}
