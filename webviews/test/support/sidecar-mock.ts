// A `webkit.messageHandlers.cmuxDiff` stand-in for the typed sidecar
// transport: answers the handshake with the given capabilities, opens and
// closes sessions, and confirms write commands. Per-method overrides shape
// failure paths.

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
        case "worktreeCommit":
          return {
            id: request.id,
            version: 1,
            result: { type: "committed", value: { commit: MOCK_COMMIT } },
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
