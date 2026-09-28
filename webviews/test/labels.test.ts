import { describe, expect, test } from "bun:test";
import {
  createDiffViewerLabelResolver,
  DIFF_VIEWER_LABEL_KEYS,
  formatLabel,
} from "../src/labels";

describe("createDiffViewerLabelResolver", () => {
  test("uses localized payload labels first", () => {
    const label = createDiffViewerLabelResolver({
      hideFiles: "Hide changed files",
    });

    expect(label("hideFiles")).toBe("Hide changed files");
  });

  test("falls back to shipped default labels instead of raw keys", () => {
    const label = createDiffViewerLabelResolver(undefined);

    expect(label("hideFiles")).toBe("Hide files");
  });

  test("fails fast for missing payload labels in development mode", () => {
    const label = createDiffViewerLabelResolver(undefined, {
      assertMissing: true,
    });

    expect(() => label("hideFiles")).toThrow(
      "Missing cmux diff viewer label: hideFiles",
    );
  });

  test("deduplicates missing payload label assertions", () => {
    const label = createDiffViewerLabelResolver(undefined, {
      assertMissing: true,
    });

    expect(() => label("hideFiles")).toThrow(
      "Missing cmux diff viewer label: hideFiles",
    );
    expect(label("hideFiles")).toBe("Hide files");
  });

  test("falls back to defaults for empty payload labels", () => {
    const label = createDiffViewerLabelResolver({ hideFiles: "  " });

    expect(label("hideFiles")).toBe("Hide files");
  });

  test("ships a non-empty default for every header, forge, and file-card label", () => {
    const label = createDiffViewerLabelResolver(undefined);
    const required = [
      "aheadBy",
      "authRequired",
      "behindBy",
      "changedFilesCount",
      "checksFailed",
      "checksPassed",
      "checksPending",
      "commitActions",
      "confirmDiscardAll",
      "copiedPath",
      "copyPath",
      "copyPathFailed",
      "createMergeRequest",
      "createMergeRequestDialog",
      "createMergeRequestSubmit",
      "createPullRequest",
      "createPullRequestDialog",
      "createPullRequestSubmit",
      "detachedHead",
      "detachedHeadShort",
      "discardAll",
      "discardAllPrompt",
      "forgeCliMissing",
      "forgeNotAuthenticated",
      "forgeUnavailable",
      "moreActions",
      "noRemote",
      "noUpstreamShort",
      "openInCmux",
      "openInCmuxFailed",
      "openMergeRequest",
      "openPullRequest",
      "prStateClosed",
      "prStateDraft",
      "prStateMerged",
      "prStateOpen",
      "pullRequestBase",
      "pullRequestBaseInvalid",
      "pullRequestBasePlaceholder",
      "pullRequestBodyInvalid",
      "pullRequestBodyPlaceholder",
      "pullRequestCreateFailed",
      "pullRequestCreated",
      "pullRequestDraft",
      "pullRequestExists",
      "pullRequestTitleInvalid",
      "pullRequestTitlePlaceholder",
      "push",
      "pushNoUpstream",
      "pushRejected",
      "pushed",
      "pushedUpstreamCreated",
      "reviewApproved",
      "reviewChangesRequested",
      "reviewRequired",
      "stageAll",
      "stageAllAndCommit",
      "unstageAll",
    ] as const;
    for (const key of required) {
      expect(DIFF_VIEWER_LABEL_KEYS).toContain(key);
      expect(label(key).trim()).not.toBe("");
    }
    // Keys are unique and sorted for parity checks against the host's map.
    expect(new Set(DIFF_VIEWER_LABEL_KEYS).size).toBe(
      DIFF_VIEWER_LABEL_KEYS.length,
    );
  });
});

describe("formatLabel", () => {
  test("substitutes named placeholders and leaves unknown ones in place", () => {
    expect(
      formatLabel("Pushed {branch} to {remote}", {
        branch: "main",
        remote: "origin",
      }),
    ).toBe("Pushed main to origin");
    expect(formatLabel("{count} files", { count: 3 })).toBe("3 files");
    expect(formatLabel("{missing} stays", {})).toBe("{missing} stays");
  });
});
