import Foundation

extension CMUXCLI {
    /// Emits either the full branch picker or one bounded smart-base row. Rust
    /// requests the bounded form when opening a branch session so repositories
    /// with thousands of refs do not enter the initial diff-generation path.
    func runDiffViewerRefsCommand(commandArgs: [String]) throws {
        var repo: String?
        var base: String?
        var token: String?
        var suggestedOnly = false
        var index = 0
        while index < commandArgs.count {
            switch commandArgs[index] {
            case "--repo":
                guard index + 1 < commandArgs.count else { throw CLIError(message: "__diff-viewer-refs --repo requires a path") }
                repo = commandArgs[index + 1]; index += 2
            case "--base":
                guard index + 1 < commandArgs.count else { throw CLIError(message: "__diff-viewer-refs --base requires a ref") }
                base = commandArgs[index + 1]; index += 2
            case "--token":
                guard index + 1 < commandArgs.count else { throw CLIError(message: "__diff-viewer-refs --token requires a value") }
                token = commandArgs[index + 1]; index += 2
            case "--suggested-only":
                suggestedOnly = true; index += 1
            default:
                throw CLIError(message: "Unexpected __diff-viewer-refs argument: \(commandArgs[index])")
            }
        }
        guard let repo, !repo.isEmpty else {
            throw CLIError(message: "__diff-viewer-refs requires --repo")
        }
        let rootDirectory = try diffViewerDirectory()
        let repoAuthorized = if let token, !token.isEmpty {
            diffViewerTokenAllowsRepo(token, repoRoot: repo, rootDirectory: rootDirectory)
        } else {
            diffViewerRepoIsAllowed(repo, rootDirectory: rootDirectory)
        }
        guard repoAuthorized else {
            throw CLIError(message: "Repository is not in the diff viewer allow-list")
        }
        let data: Data
        if suggestedOnly {
            let groups: [[String: Any]]
            if let resolved = try? resolvedDiffBranchBase(base, in: repo) {
                groups = [[
                    "id": "suggested",
                    "label": CMUXDiffViewerLocalization.string(
                        "diffViewer.refGroup.suggested",
                        defaultValue: "Suggested"
                    ),
                    "rows": [[
                        "ref": resolved.ref,
                        "label": resolved.ref,
                        "secondary": diffBranchBaseReasonLabel(resolved.reason),
                        "reason": resolved.reason,
                        "confidence": resolved.confidence,
                    ]],
                ]]
            } else {
                groups = []
            }
            data = try JSONSerialization.data(withJSONObject: ["groups": groups], options: [.sortedKeys])
        } else {
            data = cachedDiffBranchRefGroupsPayloadForCLI(
                repoRoot: repo,
                selectedBaseRef: base,
                rootDirectory: rootDirectory
            )
        }
        cliWriteStdout(data)
        cliWriteStdout(Data("\n".utf8))
    }

    /// Writes one viewer document for the typed sidecar path. Source and repo
    /// changes open a new Rust session inside that document, so the modern path
    /// does not prebuild the legacy source x repository x base page matrix.
    func writeTypedGitDiffViewerPage(
        selectedSource: DiffSource,
        titleOverride: String?,
        layout: String,
        layoutSource: String,
        appearance: DiffViewerAppearance,
        context: DiffSourceContext,
        target: DiffViewerGitHTMLSetTarget,
        extraAllowedPageURL: URL?
    ) throws -> DiffViewerWriteResult {
        let repoRoot = try gitRepoRootForDiff(context)
        let fileURL = target.directory.appendingPathComponent(
            "diff-\(target.groupID)-viewer.html",
            isDirectory: false
        )
        let viewerURL = try target.mapper.viewerURL(for: fileURL)
        let assets = try ensureDiffViewerAssets(nextTo: fileURL, runtime: target.runtime)
        let sharedPayload = DiffViewerSharedPayload(
            labels: DiffViewerLabels.localized().jsonObject,
            shortcuts: diffViewerShortcutPayload(),
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )
        let repoCandidates = gitDiffViewerRepoOptions(selectedRepoRoot: repoRoot, context: context)
        let session = DiffViewerBranchSession(
            token: target.mapper.token,
            groupID: target.groupID,
            repoRoot: repoRoot,
            allowedRepoRoots: repoCandidates.map(\.repoRoot),
            layout: layout,
            layoutSource: layoutSource,
            appearance: appearance,
            titleOverride: titleOverride,
            workspaceId: context.workspaceId,
            surfaceId: context.surfaceId
        )
        try writeDiffViewerBranchSession(session, rootDirectory: target.directory)
        let lastTurnInput = try? readGitDiffInput(source: .lastTurn, context: context)

        func sessionSource(_ source: DiffSource, repo: String) -> [String: Any]? {
            switch source {
            case .unstaged:
                return ["kind": "unstaged", "repoRoot": repo]
            case .staged:
                return ["kind": "staged", "repoRoot": repo]
            case .branch:
                var payload: [String: Any] = ["kind": "branch", "repoRoot": repo]
                if repo == repoRoot,
                   let base = normalizedDiffSourceValue(context.branchBaseRef) {
                    payload["baseRef"] = base
                }
                return payload
            case .lastTurn:
                guard lastTurnInput != nil else { return nil }
                return [
                    "kind": "patch",
                    "path": "/\(diffViewerPatchFileURL(for: fileURL).lastPathComponent)",
                ]
            }
        }
        let sourceOptions = DiffSource.allCases.map { source in
            let typedSource = sessionSource(source, repo: repoRoot)
            return DiffViewerSourceOption(
                value: source.slug,
                label: source.menuLabel,
                selected: source == selectedSource,
                url: nil,
                disabled: typedSource == nil && source != selectedSource,
                message: nil,
                sourceLabel: nil,
                sessionSource: typedSource
            )
        }
        let repoOptions: [DiffViewerSourceOption]
        if repoCandidates.count > 1 {
            repoOptions = repoCandidates.map { option in
                DiffViewerSourceOption(
                    value: option.repoRoot,
                    label: option.label,
                    selected: option.repoRoot == repoRoot,
                    url: nil,
                    disabled: false,
                    message: option.repoRoot,
                    sourceLabel: nil,
                    sessionSource: sessionSource(selectedSource, repo: option.repoRoot)
                )
            }
        } else {
            repoOptions = []
        }

        var responseInput: DiffInput
        if selectedSource == .lastTurn {
            do {
                responseInput = try nonEmptyGitDiffInput(source: selectedSource, context: context)
                try writeDiffViewerHTML(
                    to: fileURL,
                    patch: responseInput.patch,
                    title: titleOverride ?? responseInput.defaultTitle,
                    sourceLabel: responseInput.sourceLabel,
                    externalURL: responseInput.externalURL,
                    remotePatchURL: responseInput.remotePatchURL,
                    layout: layout,
                    layoutSource: layoutSource,
                    appearance: appearance,
                    sourceOptions: sourceOptions,
                    repoOptions: repoOptions,
                    repoRoot: repoRoot,
                    sessionSource: sessionSource(.lastTurn, repo: repoRoot),
                    capabilityToken: target.mapper.token,
                    assets: assets,
                    sharedPayload: sharedPayload,
                    runtime: target.runtime
                )
            } catch let error as EmptyDiffSourceError {
                responseInput = DiffInput(
                    patch: "",
                    sourceLabel: "git \(selectedSource.slug)",
                    defaultTitle: selectedSource.title,
                    emptyMessage: error.message,
                    externalURL: nil
                )
                try writeDiffViewerStatusHTML(
                    to: fileURL,
                    title: titleOverride ?? selectedSource.title,
                    sourceLabel: responseInput.sourceLabel,
                    message: error.message,
                    isError: false,
                    pollForReplacement: false,
                    layout: layout,
                    layoutSource: layoutSource,
                    appearance: appearance,
                    sourceOptions: sourceOptions,
                    repoOptions: repoOptions,
                    repoRoot: repoRoot,
                    sessionSource: sessionSource(.lastTurn, repo: repoRoot),
                    capabilityToken: target.mapper.token,
                    assets: assets,
                    sharedPayload: sharedPayload,
                    runtime: target.runtime
                )
            }
        } else {
            let selectedSessionSource = sessionSource(selectedSource, repo: repoRoot)
            responseInput = DiffInput(
                patch: "",
                sourceLabel: "git \(selectedSource.slug)",
                defaultTitle: selectedSource.title,
                emptyMessage: selectedSource.emptyMessage,
                externalURL: nil
            )
            try writeDiffViewerStatusHTML(
                to: fileURL,
                title: titleOverride ?? selectedSource.title,
                sourceLabel: responseInput.sourceLabel,
                message: diffViewerLoadingDiffMessage(selectedSource.menuLabel),
                emptyMessage: selectedSource.emptyMessage,
                isError: false,
                pollForReplacement: true,
                layout: layout,
                layoutSource: layoutSource,
                appearance: appearance,
                sourceOptions: sourceOptions,
                repoOptions: repoOptions,
                repoRoot: repoRoot,
                branchBaseRef: context.branchBaseRef,
                sessionSource: selectedSessionSource,
                capabilityToken: target.mapper.token,
                assets: assets,
                sharedPayload: sharedPayload,
                runtime: target.runtime
            )
            if let lastTurnInput {
                try lastTurnInput.patch.write(
                    to: diffViewerPatchFileURL(for: fileURL),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }

        var pageURLs = [fileURL]
        if let extraAllowedPageURL { pageURLs.append(extraAllowedPageURL) }
        let allowedFiles = try diffViewerAllowedFiles(
            pageURLs: pageURLs,
            assets: assets,
            mapper: target.mapper
        )
        try writeDiffViewerHTTPManifest(
            token: target.mapper.token,
            files: allowedFiles,
            rootDirectory: target.directory
        )
        return DiffViewerWriteResult(
            fileURL: fileURL,
            url: viewerURL,
            title: titleOverride ?? responseInput.defaultTitle,
            input: responseInput,
            allowedFiles: allowedFiles
        )
    }

    /// Writes the first paint without loading or hashing the web application.
    /// The host can register and open this document immediately, then navigate
    /// the same surface after the typed session document is ready.
    func writeDiffViewerOpeningHTML(
        to viewerURL: URL,
        title: String,
        message: String,
        appearance: DiffViewerAppearance
    ) throws {
        let escapedTitle = htmlEscaped(title)
        let escapedMessage = htmlEscaped(message)
        let html = """
        <!doctype html>
        <html data-cmux-diff-pending="true">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escapedTitle)</title>
          \(diffViewerPrepaintStyle(appearance: appearance))
          <style>
            body { margin: 0; color: var(--cmux-diff-fg); font: 13px -apple-system, BlinkMacSystemFont, sans-serif; }
            .loading { display: flex; align-items: center; gap: 10px; margin: 20px 16px; opacity: .72; }
            .spinner { width: 16px; height: 16px; border: 3px solid currentColor; border-right-color: transparent; border-radius: 50%; animation: spin .7s linear infinite; }
            .skeleton { margin: 38px 20px; display: grid; gap: 20px; opacity: .12; }
            .skeleton i { display: block; height: 14px; border-radius: 6px; background: currentColor; }
            .skeleton i:nth-child(2n) { width: 72%; }
            @keyframes spin { to { transform: rotate(360deg); } }
          </style>
        </head>
        <body>
          <div class="loading"><span class="spinner"></span><span>\(escapedMessage)</span></div>
          <div class="skeleton"><i></i><i></i><i></i><i></i><i></i><i></i></div>
        </body>
        </html>
        """
        try html.write(to: viewerURL, atomically: true, encoding: .utf8)
    }
}

extension CMUXCLI.DiffViewerLabels {
    /// Labels for the diff viewer's working-tree write actions (revert, stage,
    /// unstage, revert hunk, commit), the repository header with its push /
    /// pull request actions, and the per-file open / copy utilities. Keys
    /// mirror `webviews/src/labels.ts`; the existing `commit` label stays the
    /// "Commit N" series prefix.
    static func worktreeWriteValues() -> [String: String] {
        [
            "aheadBy": CMUXDiffViewerLocalization.string("diffViewer.aheadBy", defaultValue: "{count} ahead"),
            "authRequired": CMUXDiffViewerLocalization.string("diffViewer.authRequired", defaultValue: "Git could not authenticate with the remote. Sign in with your credential helper or SSH agent, then try again."),
            "behindBy": CMUXDiffViewerLocalization.string("diffViewer.behindBy", defaultValue: "{count} behind"),
            "cancel": CMUXDiffViewerLocalization.string("diffViewer.cancel", defaultValue: "Cancel"),
            "changedFilesCount": CMUXDiffViewerLocalization.string("diffViewer.changedFilesCount", defaultValue: "{count} files"),
            "checksFailed": CMUXDiffViewerLocalization.string("diffViewer.checksFailed", defaultValue: "{count} failed"),
            "checksPassed": CMUXDiffViewerLocalization.string("diffViewer.checksPassed", defaultValue: "{passed}/{total} checks passed"),
            "checksPending": CMUXDiffViewerLocalization.string("diffViewer.checksPending", defaultValue: "{count} pending"),
            "commitActions": CMUXDiffViewerLocalization.string("diffViewer.commitActions", defaultValue: "More commit actions"),
            "commitChanges": CMUXDiffViewerLocalization.string("diffViewer.commitChanges", defaultValue: "Commit changes"),
            "commitFailed": CMUXDiffViewerLocalization.string("diffViewer.commitFailed", defaultValue: "Could not create the commit."),
            "commitMessageInvalid": CMUXDiffViewerLocalization.string("diffViewer.commitMessageInvalid", defaultValue: "Enter a commit message of at most 64 KiB."),
            "commitMessagePlaceholder": CMUXDiffViewerLocalization.string("diffViewer.commitMessagePlaceholder", defaultValue: "Commit message"),
            "commitSubmit": CMUXDiffViewerLocalization.string("diffViewer.commitSubmit", defaultValue: "Commit"),
            "committed": CMUXDiffViewerLocalization.string("diffViewer.committed", defaultValue: "Committed {commit}"),
            "confirmDiscardAll": CMUXDiffViewerLocalization.string("diffViewer.confirmDiscardAll", defaultValue: "Discard all"),
            "confirmRevert": CMUXDiffViewerLocalization.string("diffViewer.confirmRevert", defaultValue: "Revert"),
            "copiedPath": CMUXDiffViewerLocalization.string("diffViewer.copiedPath", defaultValue: "Copied path"),
            "copyPath": CMUXDiffViewerLocalization.string("diffViewer.copyPath", defaultValue: "Copy path"),
            "copyPathFailed": CMUXDiffViewerLocalization.string("diffViewer.copyPathFailed", defaultValue: "Could not copy path."),
            "createMergeRequest": CMUXDiffViewerLocalization.string("diffViewer.createMergeRequest", defaultValue: "Create MR"),
            "createMergeRequestDialog": CMUXDiffViewerLocalization.string("diffViewer.createMergeRequestDialog", defaultValue: "Create merge request"),
            "createMergeRequestSubmit": CMUXDiffViewerLocalization.string("diffViewer.createMergeRequestSubmit", defaultValue: "Create merge request"),
            "createPullRequest": CMUXDiffViewerLocalization.string("diffViewer.createPullRequest", defaultValue: "Create PR"),
            "createPullRequestDialog": CMUXDiffViewerLocalization.string("diffViewer.createPullRequestDialog", defaultValue: "Create pull request"),
            "createPullRequestSubmit": CMUXDiffViewerLocalization.string("diffViewer.createPullRequestSubmit", defaultValue: "Create pull request"),
            "detachedHead": CMUXDiffViewerLocalization.string("diffViewer.detachedHead", defaultValue: "HEAD is detached. Check out a branch first."),
            "detachedHeadShort": CMUXDiffViewerLocalization.string("diffViewer.detachedHeadShort", defaultValue: "detached"),
            "discardAll": CMUXDiffViewerLocalization.string("diffViewer.discardAll", defaultValue: "Discard all changes…"),
            "discardAllPrompt": CMUXDiffViewerLocalization.string("diffViewer.discardAllPrompt", defaultValue: "Discard every change in this view? This cannot be undone."),
            "forgeCliMissing": CMUXDiffViewerLocalization.string("diffViewer.forgeCliMissing", defaultValue: "Install the GitHub CLI (gh) or GitLab CLI (glab) to use this action."),
            "forgeNotAuthenticated": CMUXDiffViewerLocalization.string("diffViewer.forgeNotAuthenticated", defaultValue: "Sign in with gh auth login or glab auth login, then try again."),
            "forgeUnavailable": CMUXDiffViewerLocalization.string("diffViewer.forgeUnavailable", defaultValue: "Not available for this remote."),
            "hunkStale": CMUXDiffViewerLocalization.string("diffViewer.hunkStale", defaultValue: "This hunk changed on disk. The diff was reloaded."),
            "moreActions": CMUXDiffViewerLocalization.string("diffViewer.moreActions", defaultValue: "More actions"),
            "noRemote": CMUXDiffViewerLocalization.string("diffViewer.noRemote", defaultValue: "The repository has no remote."),
            "noUpstreamShort": CMUXDiffViewerLocalization.string("diffViewer.noUpstreamShort", defaultValue: "no upstream"),
            "nothingToCommit": CMUXDiffViewerLocalization.string("diffViewer.nothingToCommit", defaultValue: "Nothing to commit."),
            "openInCmux": CMUXDiffViewerLocalization.string("diffViewer.openInCmux", defaultValue: "Open in cmux"),
            "openInCmuxFailed": CMUXDiffViewerLocalization.string("diffViewer.openInCmuxFailed", defaultValue: "Could not open the file in cmux."),
            "openMergeRequest": CMUXDiffViewerLocalization.string("diffViewer.openMergeRequest", defaultValue: "Open merge request"),
            "openPullRequest": CMUXDiffViewerLocalization.string("diffViewer.openPullRequest", defaultValue: "Open pull request"),
            "prStateClosed": CMUXDiffViewerLocalization.string("diffViewer.prStateClosed", defaultValue: "Closed"),
            "prStateDraft": CMUXDiffViewerLocalization.string("diffViewer.prStateDraft", defaultValue: "Draft"),
            "prStateMerged": CMUXDiffViewerLocalization.string("diffViewer.prStateMerged", defaultValue: "Merged"),
            "prStateOpen": CMUXDiffViewerLocalization.string("diffViewer.prStateOpen", defaultValue: "Open"),
            "pullRequestBase": CMUXDiffViewerLocalization.string("diffViewer.pullRequestBase", defaultValue: "into {base}"),
            "pullRequestBaseInvalid": CMUXDiffViewerLocalization.string("diffViewer.pullRequestBaseInvalid", defaultValue: "Enter a valid base branch name."),
            "pullRequestBasePlaceholder": CMUXDiffViewerLocalization.string("diffViewer.pullRequestBasePlaceholder", defaultValue: "Base branch (default)"),
            "pullRequestBodyInvalid": CMUXDiffViewerLocalization.string("diffViewer.pullRequestBodyInvalid", defaultValue: "The description is too long (64 KiB max)."),
            "pullRequestBodyPlaceholder": CMUXDiffViewerLocalization.string("diffViewer.pullRequestBodyPlaceholder", defaultValue: "Description (optional)"),
            "pullRequestCreateFailed": CMUXDiffViewerLocalization.string("diffViewer.pullRequestCreateFailed", defaultValue: "Could not create the pull request."),
            "pullRequestCreated": CMUXDiffViewerLocalization.string("diffViewer.pullRequestCreated", defaultValue: "Created #{number}"),
            "pullRequestDraft": CMUXDiffViewerLocalization.string("diffViewer.pullRequestDraft", defaultValue: "Create as draft"),
            "pullRequestExists": CMUXDiffViewerLocalization.string("diffViewer.pullRequestExists", defaultValue: "A pull request already exists for this branch."),
            "pullRequestTitleInvalid": CMUXDiffViewerLocalization.string("diffViewer.pullRequestTitleInvalid", defaultValue: "Enter a title of at most 256 bytes."),
            "pullRequestTitlePlaceholder": CMUXDiffViewerLocalization.string("diffViewer.pullRequestTitlePlaceholder", defaultValue: "Title"),
            "push": CMUXDiffViewerLocalization.string("diffViewer.push", defaultValue: "Push"),
            "pushNoUpstream": CMUXDiffViewerLocalization.string("diffViewer.pushNoUpstream", defaultValue: "The branch has no upstream yet."),
            "pushRejected": CMUXDiffViewerLocalization.string("diffViewer.pushRejected", defaultValue: "The remote rejected the push."),
            "pushed": CMUXDiffViewerLocalization.string("diffViewer.pushed", defaultValue: "Pushed {branch} to {remote}"),
            "pushedUpstreamCreated": CMUXDiffViewerLocalization.string("diffViewer.pushedUpstreamCreated", defaultValue: "Pushed {branch} to {remote} and set the upstream"),
            "reviewApproved": CMUXDiffViewerLocalization.string("diffViewer.reviewApproved", defaultValue: "Approved"),
            "reviewChangesRequested": CMUXDiffViewerLocalization.string("diffViewer.reviewChangesRequested", defaultValue: "Changes requested"),
            "reviewRequired": CMUXDiffViewerLocalization.string("diffViewer.reviewRequired", defaultValue: "Review required"),
            "revertFile": CMUXDiffViewerLocalization.string("diffViewer.revertFile", defaultValue: "Revert changes"),
            "revertHunk": CMUXDiffViewerLocalization.string("diffViewer.revertHunk", defaultValue: "Revert hunk"),
            "revertPrompt": CMUXDiffViewerLocalization.string("diffViewer.revertPrompt", defaultValue: "Discard these changes?"),
            "stageAll": CMUXDiffViewerLocalization.string("diffViewer.stageAll", defaultValue: "Stage all"),
            "stageAllAndCommit": CMUXDiffViewerLocalization.string("diffViewer.stageAllAndCommit", defaultValue: "Stage all and commit"),
            "stageFile": CMUXDiffViewerLocalization.string("diffViewer.stageFile", defaultValue: "Stage file"),
            "unstageAll": CMUXDiffViewerLocalization.string("diffViewer.unstageAll", defaultValue: "Unstage all"),
            "unstageFile": CMUXDiffViewerLocalization.string("diffViewer.unstageFile", defaultValue: "Unstage file"),
            "worktreeConflict": CMUXDiffViewerLocalization.string("diffViewer.worktreeConflict", defaultValue: "The change could not be applied cleanly. The diff was reloaded."),
            "worktreeNotAllowed": CMUXDiffViewerLocalization.string("diffViewer.worktreeNotAllowed", defaultValue: "Working-tree changes are not available for this diff."),
            "worktreePartialRevert": CMUXDiffViewerLocalization.string("diffViewer.worktreePartialRevert", defaultValue: "The change was unstaged but is still in the working tree. The diff was reloaded."),
            "worktreeWriteFailed": CMUXDiffViewerLocalization.string("diffViewer.worktreeWriteFailed", defaultValue: "Could not update the working tree."),
        ]
    }
}
