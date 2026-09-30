import { describe, expect, test } from "bun:test";
import {
  createDiffViewerLabelResolver,
  DIFF_VIEWER_LABEL_KEYS,
  formatCountLabel,
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
      // Batch actions: the header's Discard all… text, the selection forms
      // (template plus singular), the confirm, the select-all and the
      // per-row checkbox names.
      "clearSelection",
      "confirmDiscardSelected",
      "discardAllShort",
      "discardSelected",
      "discardSelectedOne",
      "discardSelectedPrompt",
      "selectAllFiles",
      "selectFile",
      "stageSelected",
      "stageSelectedOne",
      "unstageSelected",
      "unstageSelectedOne",
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

describe("formatCountLabel", () => {
  test("picks the singular key for exactly one and fills {count} otherwise", () => {
    const label = createDiffViewerLabelResolver(undefined);
    expect(formatCountLabel(label, "stageSelected", 1)).toBe("Stage 1 file");
    expect(formatCountLabel(label, "stageSelected", 2)).toBe("Stage 2 files");
    expect(formatCountLabel(label, "unstageSelected", 12)).toBe(
      "Unstage 12 files",
    );
    expect(formatCountLabel(label, "discardSelected", 1)).toBe(
      "Discard 1 file…",
    );
    expect(formatCountLabel(label, "discardSelected", 0)).toBe(
      "Discard 0 files…",
    );
    // Localized payloads win for both forms.
    const localized = createDiffViewerLabelResolver({
      stageSelected: "{count} Dateien stagen",
      stageSelectedOne: "1 Datei stagen",
    });
    expect(formatCountLabel(localized, "stageSelected", 1)).toBe(
      "1 Datei stagen",
    );
    expect(formatCountLabel(localized, "stageSelected", 3)).toBe(
      "3 Dateien stagen",
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
