use serde::{Deserialize, Serialize};
use ts_rs::TS;

use crate::PROTOCOL_VERSION;

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct DiffRequest {
    pub id: String,
    pub version: u32,
    #[serde(flatten)]
    pub command: DiffCommand,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(tag = "method", content = "params", rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub enum DiffCommand {
    ProtocolHandshake,
    SessionOpen(OpenSessionRequest),
    SessionClose(SessionRequest),
    BranchList(BranchListRequest),
    BranchChange(BranchChangeRequest),
    WorktreeStageFiles(WorktreeFilesRequest),
    WorktreeUnstageFiles(WorktreeFilesRequest),
    WorktreeDiscardFiles(WorktreeFilesRequest),
    WorktreeDiscardHunk(WorktreeHunkRequest),
    WorktreeCommit(WorktreeCommitRequest),
    WorktreeDiscardAll(WorktreeSessionRequest),
    WorktreeStageAll(WorktreeSessionRequest),
    WorktreeUnstageAll(WorktreeSessionRequest),
    WorktreePush(WorktreePushRequest),
    WorktreeRepositoryStatus(WorktreeSessionRequest),
    WorktreeCreatePullRequest(WorktreeCreatePullRequestRequest),
}

impl DiffCommand {
    /// Whether the command mutates a repository's index or working tree.
    ///
    /// Write commands are only reachable through the native stdio transport;
    /// the loopback HTTP and WebSocket development routes reject them.
    #[must_use]
    pub fn is_worktree_write(&self) -> bool {
        // Exhaustive on purpose: a new command must declare which side of
        // the transport boundary it belongs to.
        match self {
            // The status query only reads, but it still runs the forge CLI on
            // the host, so it is limited to the stdio transport with the
            // writes (see `requires_stdio`).
            Self::ProtocolHandshake
            | Self::SessionOpen(_)
            | Self::SessionClose(_)
            | Self::BranchList(_)
            | Self::BranchChange(_)
            | Self::WorktreeRepositoryStatus(_) => false,
            Self::WorktreeStageFiles(_)
            | Self::WorktreeUnstageFiles(_)
            | Self::WorktreeDiscardFiles(_)
            | Self::WorktreeDiscardHunk(_)
            | Self::WorktreeCommit(_)
            | Self::WorktreeDiscardAll(_)
            | Self::WorktreeStageAll(_)
            | Self::WorktreeUnstageAll(_)
            | Self::WorktreePush(_)
            | Self::WorktreeCreatePullRequest(_) => true,
        }
    }

    /// Whether the command is reachable only through the native stdio
    /// transport: every working-tree write, plus the repository status query,
    /// which runs Git network queries and the forge CLI on the host.
    #[must_use]
    pub fn requires_stdio(&self) -> bool {
        self.is_worktree_write() || matches!(self, Self::WorktreeRepositoryStatus(_))
    }
}

/// The transport a request arrived on. Working-tree writes exist only on the
/// native stdio transport, so only that transport advertises them.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RpcTransport {
    /// One request per process over stdin/stdout, driven by the native host.
    Stdio,
    /// The loopback HTTP and WebSocket development routes.
    Loopback,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct OpenSessionRequest {
    pub source: DiffSource,
    pub capability_token: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub session_id: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
#[ts(export_to = "protocol.ts")]
pub enum DiffSource {
    Patch {
        path: String,
    },
    Unstaged {
        repo_root: String,
    },
    Staged {
        repo_root: String,
    },
    Branch {
        repo_root: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        base_ref: Option<String>,
    },
}

/// The variant of a [`DiffSource`] without its parameters; a session is bound
/// to one kind for its lifetime.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum DiffSourceKind {
    Patch,
    Unstaged,
    Staged,
    Branch,
}

impl DiffSource {
    #[must_use]
    pub fn kind(&self) -> DiffSourceKind {
        match self {
            Self::Patch { .. } => DiffSourceKind::Patch,
            Self::Unstaged { .. } => DiffSourceKind::Unstaged,
            Self::Staged { .. } => DiffSourceKind::Staged,
            Self::Branch { .. } => DiffSourceKind::Branch,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct SessionRequest {
    pub session_id: String,
    pub capability_token: String,
}

/// Targets the files of an open `unstaged` or `staged` session for one Git
/// invocation (stage, unstage, or discard a selection; a single file is a
/// one-element list). `paths` are repository-relative and validated by the
/// sidecar; a rename contributes both of its names. An empty list is refused.
#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct WorktreeFilesRequest {
    pub session_id: String,
    pub capability_token: String,
    pub source: DiffSource,
    pub paths: Vec<String>,
}

/// Identifies one hunk by its `@@ -old,count +new,count @@` header ranges.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct HunkRef {
    pub old_start: u32,
    pub old_count: u32,
    pub new_start: u32,
    pub new_count: u32,
}

/// Targets one hunk of one file. `previous_path` names the rename origin of a
/// staged rename so the sidecar re-reads the diff with both names in scope.
#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct WorktreeHunkRequest {
    pub session_id: String,
    pub capability_token: String,
    pub source: DiffSource,
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub previous_path: Option<String>,
    pub hunk: HunkRef,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct WorktreeCommitRequest {
    pub session_id: String,
    pub capability_token: String,
    pub source: DiffSource,
    pub message: String,
    /// Stage every tracked change (`git add --update`) before committing, so
    /// an unstaged view can offer "stage all and commit" as one action.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub stage_all: bool,
}

/// Targets a whole open `unstaged` or `staged` session (discard all, stage
/// all, unstage all, repository status).
#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct WorktreeSessionRequest {
    pub session_id: String,
    pub capability_token: String,
    pub source: DiffSource,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct WorktreePushRequest {
    pub session_id: String,
    pub capability_token: String,
    pub source: DiffSource,
    /// Create the upstream (`git push -u`) when the branch has none.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub set_upstream: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct WorktreeCreatePullRequestRequest {
    pub session_id: String,
    pub capability_token: String,
    pub source: DiffSource,
    pub title: String,
    #[serde(default)]
    pub body: String,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub draft: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub base: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct PushResult {
    pub remote: String,
    pub branch: String,
    pub upstream_created: bool,
}

/// The forge a repository's remote points at, from its URL.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub enum RepositoryHostKind {
    Github,
    Gitlab,
    Other,
    None,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub enum ForgeCliKind {
    Gh,
    Glab,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct ForgeCliStatus {
    pub available: bool,
    pub authenticated: bool,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct ChecksSummary {
    pub total: u32,
    pub passed: u32,
    pub failed: u32,
    pub pending: u32,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct PullRequestSummary {
    pub number: u64,
    pub url: String,
    pub title: String,
    /// `open`, `merged`, or `closed`, normalized across forges.
    pub state: String,
    pub is_draft: bool,
    pub base_branch: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub review_decision: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub checks: Option<ChecksSummary>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct RepositoryStatus {
    pub branch: String,
    pub detached: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub upstream: Option<String>,
    pub ahead: u32,
    pub behind: u32,
    pub host_kind: RepositoryHostKind,
    pub forge_cli: ForgeCliStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub pull_request: Option<PullRequestSummary>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct PullRequestCreated {
    pub number: u64,
    pub url: String,
    pub title: String,
    pub is_draft: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct WorktreeMutated {
    pub source: DiffSource,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct CommitResult {
    pub commit: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct BranchListRequest {
    pub repo_root: String,
    pub capability_token: String,
    pub selected_base: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct BranchChangeRequest {
    pub group_id: String,
    pub repo_root: String,
    pub base_ref: String,
    pub capability_token: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct BranchListResult {
    pub groups: Vec<BranchPickerGroup>,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct BranchPickerGroup {
    pub id: String,
    pub label: String,
    pub rows: Vec<BranchPickerRow>,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct BranchPickerRow {
    pub r#ref: String,
    pub label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub secondary: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub confidence: Option<BranchPickerConfidence>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub current: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub worktree_dir: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub enum BranchPickerConfidence {
    High,
    Low,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct DiffResourceRef {
    pub id: String,
    pub media_type: String,
    pub byte_length: Option<u64>,
    pub revision: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct DiffTransportConfig {
    pub kind: DiffTransportKind,
    pub endpoint: String,
    pub protocol_version: u32,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub enum DiffTransportKind {
    Fetch,
    WebSocket,
    WebKit,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct DiffResponse {
    pub id: String,
    pub version: u32,
    pub result: Option<DiffResult>,
    pub error: Option<DiffProtocolError>,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub enum DiffResult {
    Handshake(HandshakeResult),
    SessionOpened(SessionOpened),
    SessionClosed,
    Branches(BranchListResult),
    Navigation(NavigationResult),
    WorktreeMutated(WorktreeMutated),
    Committed(CommitResult),
    Pushed(PushResult),
    RepositoryStatus(RepositoryStatus),
    PullRequestCreated(PullRequestCreated),
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct HandshakeResult {
    pub protocol_version: u32,
    pub capabilities: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct SessionOpened {
    pub session_id: String,
    pub patch: DiffResourceRef,
    pub source: DiffSource,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct NavigationResult {
    pub url: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct DiffProtocolError {
    pub code: String,
    pub message: String,
    /// A working-tree write failed after a mutating Git child ran, or found
    /// the diff already changed under the page: the rendered diff may be
    /// stale, so the page reloads it.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    #[ts(as = "Option<bool>", optional)]
    pub state_may_have_changed: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
#[ts(export_to = "protocol.ts")]
pub enum DiffEvent {
    SessionStatus {
        session_id: String,
        status: DiffSessionStatus,
    },
    PatchReady {
        session_id: String,
        patch: DiffResourceRef,
    },
    SessionFailed {
        session_id: String,
        error: DiffProtocolError,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub enum DiffSessionStatus {
    Opening,
    Ready,
    Closed,
}

impl DiffResponse {
    #[must_use]
    pub fn success(id: String, result: DiffResult) -> Self {
        Self {
            id,
            version: PROTOCOL_VERSION,
            result: Some(result),
            error: None,
        }
    }

    #[must_use]
    pub fn failure(id: String, code: &str, message: &str) -> Self {
        Self::write_failure(id, code, message, false)
    }

    /// [`Self::failure`] for a working-tree write, carrying whether the
    /// repository may no longer match the rendered diff.
    #[must_use]
    pub fn write_failure(
        id: String,
        code: &str,
        message: &str,
        state_may_have_changed: bool,
    ) -> Self {
        Self {
            id,
            version: PROTOCOL_VERSION,
            result: None,
            error: Some(DiffProtocolError {
                code: code.to_owned(),
                message: message.to_owned(),
                state_may_have_changed,
            }),
        }
    }
}

#[must_use]
pub fn handshake(id: String, transport: RpcTransport) -> DiffResponse {
    let mut capabilities = vec![
        "resource.stream".to_owned(),
        "transport.webkit".to_owned(),
        "transport.stdio".to_owned(),
    ];
    if transport == RpcTransport::Stdio {
        capabilities.push("worktree.write".to_owned());
    }
    #[cfg(feature = "http-server")]
    capabilities.extend([
        "transport.fetch".to_owned(),
        "transport.websocket".to_owned(),
    ]);
    DiffResponse::success(
        id,
        DiffResult::Handshake(HandshakeResult {
            protocol_version: PROTOCOL_VERSION,
            capabilities,
        }),
    )
}
