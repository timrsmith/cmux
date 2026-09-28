// A `webkit.messageHandlers.cmuxDiff` stand-in for the typed sidecar
// transport: answers the handshake with the given capabilities, opens and
// closes sessions, reports a repository status, and confirms write commands.
// Per-method overrides shape failure paths.

export const MOCK_CAPABILITY_TOKEN = "0123456789abcdef";
export const MOCK_SESSION_ID = "01234567-89ab-cdef-0123-456789abcdef";
export const MOCK_COMMIT = "0123456789abcdef0123456789abcdef01234567";

export type SidecarRequest = {
  id: string;
  version: number;
  method: string;
  params?: any;
};

export type SidecarResponder = (request: SidecarRequest) => unknown;

export function handshakeResponse(
  request: SidecarRequest,
  capabilities: readonly string[],
) {
  return {
    id: request.id,
    version: 1,
    result: {
      type: "handshake",
      value: { protocolVersion: 1, capabilities: [...capabilities] },
    },
    error: null,
  };
}

export function sessionOpenedResponse(
  request: SidecarRequest,
  patchId = `cmux-diff-viewer://${MOCK_CAPABILITY_TOKEN}/diff-session.patch`,
) {
  return {
    id: request.id,
    version: 1,
    result: {
      type: "sessionOpened",
      value: {
        sessionId: MOCK_SESSION_ID,
        patch: {
          id: patchId,
          mediaType: "text/x-diff",
          byteLength: 0,
          revision: 1,
        },
        source: request.params.source,
      },
    },
    error: null,
  };
}

/** A repository on a plain (non-forge) remote with its branch pushed. */
export const MOCK_REPOSITORY_STATUS = {
  branch: "main",
  detached: false,
  upstream: "origin/main",
  ahead: 0,
  behind: 0,
  remoteUrl: "/tmp/origin.git",
  hostKind: "other",
  forgeCli: { kind: null, available: false, authenticated: false },
};

/** The same repository hosted on GitHub with a signed-in `gh`. */
export const MOCK_GITHUB_STATUS = {
  ...MOCK_REPOSITORY_STATUS,
  ahead: 2,
  remoteUrl: "https://github.com/acme/widgets.git",
  hostKind: "github",
  forgeCli: { kind: "gh", available: true, authenticated: true },
};

export const MOCK_PULL_REQUEST = {
  number: 42,
  url: "https://github.com/acme/widgets/pull/42",
  title: "Add widgets",
  state: "open",
  isDraft: true,
  baseBranch: "main",
  reviewDecision: "review_required",
  checks: { total: 3, passed: 2, failed: 0, pending: 1 },
};

export function repositoryStatusResponse(
  request: SidecarRequest,
  status: Record<string, unknown> = MOCK_REPOSITORY_STATUS,
) {
  return {
    id: request.id,
    version: 1,
    result: { type: "repositoryStatus", value: status },
    error: null,
  };
}

export function failureResponse(
  request: SidecarRequest,
  code: string,
  message: string,
) {
  return { id: request.id, version: 1, result: null, error: { code, message } };
}

/**
 * Builds the message handler. Every request is pushed onto `requests` before
 * it is answered, so tests assert on the exact envelopes the page sent.
 */
export function sidecarMock(
  requests: SidecarRequest[],
  capabilities: readonly string[],
  overrides: Record<string, SidecarResponder> = {},
) {
  return {
    async postMessage(request: SidecarRequest) {
      requests.push(request);
      const override = overrides[request.method];
      if (override) {
        return override(request);
      }
      switch (request.method) {
        case "protocolHandshake":
          return handshakeResponse(request, capabilities);
        case "sessionClose":
          return {
            id: request.id,
            version: 1,
            result: { type: "sessionClosed" },
            error: null,
          };
        case "sessionOpen":
          return sessionOpenedResponse(request);
        case "worktreeRepositoryStatus":
          return repositoryStatusResponse(request);
        case "worktreeCommit":
          return {
            id: request.id,
            version: 1,
            result: { type: "committed", value: { commit: MOCK_COMMIT } },
            error: null,
          };
        case "worktreePush":
          return {
            id: request.id,
            version: 1,
            result: {
              type: "pushed",
              value: {
                remote: "origin",
                branch: "main",
                upstreamCreated: request.params.setUpstream === true,
              },
            },
            error: null,
          };
        case "worktreeCreatePullRequest":
          return {
            id: request.id,
            version: 1,
            result: {
              type: "pullRequestCreated",
              value: {
                number: MOCK_PULL_REQUEST.number,
                url: MOCK_PULL_REQUEST.url,
                title: request.params.title,
                isDraft: request.params.draft === true,
              },
            },
            error: null,
          };
        case "hostOpenFile":
          return {
            id: request.id,
            version: 1,
            result: { type: "fileOpened" },
            error: null,
          };
        default:
          return {
            id: request.id,
            version: 1,
            result: {
              type: "worktreeMutated",
              value: { source: request.params.source },
            },
            error: null,
          };
      }
    },
  };
}
