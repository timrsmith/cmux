import { CodeView, WorkerPoolContextProvider, type CodeViewHandle, useWorkerPool } from "@pierre/diffs/react";
import { getFiletypeFromFileName, parsePatchFiles, preloadHighlighter, processFile, registerCustomTheme } from "@pierre/diffs";
import type { SelectedLineRange } from "@pierre/diffs";
import { FileTree, useFileTree } from "@pierre/trees/react";
import type { FileTree as FileTreeModel } from "@pierre/trees";
import { preparePresortedFileTreeInput } from "@pierre/trees";
import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from "react";
import "../../Resources/markdown-viewer/viewer-navigation.js";
import { copyGitApplyCommand, resolveDiffNavigationURL } from "./actions";
import { resolveDiffViewerAppearance } from "./appearance";
import { BranchBasePicker, branchPickerStateKey, type BranchPickerPayload } from "./BranchBasePicker";
import { lineTextFor, type CommentFileDiff } from "./comments/anchor";
import {
  applyCommentAnnotations,
  attachHunkActionAnnotations,
  sidebarCommentEntries,
  withCommentAnnotations,
  type CommentAnnotation,
  type SidebarCommentEntry,
} from "./comments/annotations";
import {
  deleteComment as bridgeDeleteComment,
  diffCommentsBridgeAvailable,
  saveComment as bridgeSaveComment,
} from "./comments/bridge";
import { CommentComposer } from "./comments/CommentComposer";
import { CommentsSidebarSection } from "./comments/CommentsSection";
import { commentSubmissionText } from "./comments/format";
import { resolveCommentLabels, type DiffCommentLabels } from "./comments/labels";
import { SavedComment } from "./comments/SavedComment";
import type {
  CommentDraft,
  DiffCommentRecord,
  DiffCommentSide,
} from "./comments/types";
import { useCommentsBootstrap } from "./comments/useCommentsBootstrap";
import { resolveDiffFileLanguage, resolveDiffPreloadLanguages } from "./diff-language";
import { fileName, type DiffItem, type FileTreeSource, type StreamMetrics, streamPatch } from "./diff-stream";
import { DiffHeaderMetadata } from "./diff-metadata";
import { applyPierreFileTreeGitStatus, planPierreFileTreeRefresh, selectPierreFileTreePath } from "./file-tree-refresh";
import {
  FILE_TREE_SELECTION_SPRITE,
  focusedFileRowPath,
  isPlainSpace,
  selectionDecoration,
  selectionRowPathFromComposedPath,
} from "./file-tree-selection";
import { Icon } from "./icons";
import { createDiffViewerLabelResolver, shouldAssertMissingLabels } from "./labels";
import {
  codeViewOptions,
  fileTreeUnsafeCSS,
  shikiThemeFromGhostty,
  workerHighlighterOptions,
  type DiffViewerOptions,
} from "./pierre-options";
import {
  EMPTY_SELECTION,
  pathsInRange,
  pruneSelection,
  selectAllState,
  selectAllToggleSelects,
  setPathsSelected,
  toggleSelectedPath,
  visibleFilePaths,
  type FileSelection,
} from "./selection";
import { applyDiffViewerStatusToDocument, createDiffViewerStatus } from "./status";
import { resolveToolbarOverflow } from "./toolbar-overflow";
import { useToolbarWidth } from "./useToolbarWidth";
import type { DiffViewerLabelResolver } from "./labels";
import type { DiffViewerStatus } from "./status";
import type { DiffViewerConfig } from "./types";
import { createDiffTransport, DiffTransportError, type DiffTransport } from "./diff/transport";
import { FindBar } from "./find/FindBar";
import { useDiffFind, type DiffFindController } from "./find/useDiffFind";
import { useFindKeyboard } from "./find/useFindKeyboard";
import type {
  DiffSource,
  DiffTransportConfig,
  HunkRef,
  PullRequestSummary,
  RepositoryStatus,
} from "./diff/generated/protocol";
import type { DiffCommand } from "./diff/transport";
import { createDiffWorkerPoolOptions } from "./worker-pool";
import {
  buildBulkRequest,
  buildCommitRequest,
  buildCreatePullRequestRequest,
  buildFileRequest,
  buildFilesRequest,
  buildHunkRequest,
  buildOpenFileRequest,
  buildPushRequest,
  buildRepositoryStatusRequest,
  commitAvailability,
  fileActionsForSource,
  payloadRepoLabel,
  repositoryHeaderModel,
  selectedFileTargets,
  worktreeErrorDetail,
  worktreeErrorLabelKey,
  worktreeErrorReloads,
  worktreeFileTarget,
  worktreeWriteAvailable,
  writableDiffSource,
  type BulkWriteAction,
  type FileWriteAction,
  type PullRequestDraft,
  type SelectionWriteAction,
  type WritableDiffSource,
} from "./worktree-actions";
import {
  FileCollapseToggle,
  FileSelectCheckbox,
  FileWriteActions,
  HunkWriteActions,
  useDismissOnOutsideInteraction,
  type WorktreeNotice,
} from "./WorktreeActions";
import { RepositoryHeader } from "./RepositoryHeader";
import { copyText } from "./actions";
import { formatLabel } from "./labels";
import { MenuButton, ViewOptionsMenuItems, type DiffViewerLayout } from "./ViewOptionsMenu";

type ConfigProps = {
  config: DiffViewerConfig;
  initialStatus: DiffViewerStatus;
};

type ActiveDiffSession = {
  capabilityToken: string;
  sessionId: string;
};

const registeredCustomThemeNames = new Set<string>();
const pendingSessionID = "00000000-0000-0000-0000-000000000000";

type AppState = {
  activeItemId: string;
  activeTreePath: string;
  comments: DiffCommentRecord[];
  copyFeedback: string;
  draft: CommentDraft | null;
  /**
   * Per-file fold state chosen from a card's chevron, keyed by file path so it
   * survives the in-place reload after a write (item ids can change between
   * streams). Files without an entry follow the collapse-all option.
   */
  fileCollapseOverrides: ReadonlyMap<string, boolean>;
  fileSearchOpen: boolean;
  fileSearchRequest: number;
  filesWidth: number;
  filesVisible: boolean;
  findOpen: boolean;
  findQuery: string;
  findRequest: number;
  items: DiffItem[];
  languages: string[];
  metrics: StreamMetrics | null;
  options: DiffViewerOptions;
  optionsOpen: boolean;
  /**
   * The checked files of the current working-tree view, keyed by tree
   * path (the file list's and the cards' shared key). Cleared when the
   * view changes; kept across a write reload and pruned to the paths
   * that stream back once it completes.
   */
  selectedPaths: FileSelection;
  /** The last path checked or unchecked one at a time: the start of a shift-click range. */
  selectionAnchor: string | null;
  status: DiffViewerStatus;
  treeSource: FileTreeSource | null;
};

type AppAction =
  | { type: "append-items"; items: DiffItem[] }
  | { type: "clear-selection" }
  | { type: "reset-diff"; status: DiffViewerStatus; keepSelection?: boolean }
  | { type: "remove-comment"; id: string }
  | { type: "rename-item"; oldId: string; newId: string }
  | { type: "select-paths"; paths: string[]; selected: boolean; anchor?: string }
  | { type: "set-active-item"; itemId: string; treePath?: string }
  | { type: "replace-comments"; comments: DiffCommentRecord[] }
  | { type: "set-copy-feedback"; message: string }
  | { type: "set-draft"; draft: CommentDraft | null }
  | { type: "set-file-search-open"; open: boolean }
  | { type: "request-file-search" }
  | { type: "set-find-open"; open: boolean }
  | { type: "set-find-query"; query: string }
  | { type: "request-find" }
  | { type: "set-files-width"; width: number }
  | { type: "set-files-visible"; visible: boolean }
  | { type: "set-metrics"; metrics: StreamMetrics }
  | { type: "set-option"; key: keyof DiffViewerOptions; value: any }
  | { type: "set-options-open"; open: boolean }
  | { type: "set-status"; status: DiffViewerStatus }
  | { type: "set-tree-source"; source: FileTreeSource }
  | { type: "toggle-item-collapsed"; itemId: string }
  | { type: "toggle-selected-path"; path: string }
  | { type: "upsert-comment"; comment: DiffCommentRecord };

const fileSkeletonWidths = ["82%", "64%", "76%", "58%", "70%", "46%"];
const diffSkeletonWidths = ["58%", "88%", "72%", "94%", "64%", "82%", "52%", "78%"];
const defaultWorkerModuleURL = "./assets/pierre-diffs-1.2.7-trees-1.0.0-beta.4/worker-pool/worker-portable.js";
const persistedLayoutKey = "cmux.diffViewer.layout";

function initialAppState(config: DiffViewerConfig, initialStatus: DiffViewerStatus): AppState {
  const payload = config.payload ?? {};
  return {
    activeItemId: "",
    activeTreePath: "",
    comments: [],
    copyFeedback: "",
    draft: null,
    fileCollapseOverrides: new Map(),
    fileSearchOpen: false,
    fileSearchRequest: 0,
    filesWidth: 252,
    filesVisible: true,
    findOpen: false,
    findQuery: "",
    findRequest: 0,
    items: [],
    languages: ["text"],
    metrics: null,
    options: {
      collapsed: false,
      diffIndicators: "bars",
      expandUnchanged: false,
      layout: initialDiffViewerLayout(payload),
      lineNumbers: true,
      showBackgrounds: true,
      wordDiffs: false,
      wordWrap: false,
    } as DiffViewerOptions,
    optionsOpen: false,
    selectedPaths: EMPTY_SELECTION,
    selectionAnchor: null,
    status: initialStatus,
    treeSource: null,
  };
}

function reducer(state: AppState, action: AppAction): AppState {
  switch (action.type) {
  case "append-items": {
    const nextItems = action.items.map((item) => {
      resolveDiffItemLanguage(item);
      const annotated = withCommentAnnotations(item, state.comments, state.draft);
      // The collapse-all option and the per-file overrides survive a reset, so
      // files streaming back in after a write action reload come back folded
      // the same way.
      return { ...annotated, collapsed: itemCollapsed(annotated, state) };
    });
    const languages = mergeLanguages(state.languages, nextItems.flatMap(diffItemPreloadLanguages));
    return {
      ...state,
      activeItemId: state.activeItemId || nextItems[0]?.id || "",
      items: [...state.items, ...nextItems],
      languages,
      status: state.status.loading ? createDiffViewerStatus("", { loading: false }) : state.status,
    };
  }
  case "clear-selection":
    return state.selectedPaths.size === 0
      ? state
      : { ...state, selectedPaths: EMPTY_SELECTION, selectionAnchor: null };
  case "reset-diff":
    // A write reload keeps the selection (the paths acted on leave it
    // when the stream completes); any other reset is a different view.
    return {
      ...state,
      activeItemId: "",
      activeTreePath: "",
      draft: null,
      items: [],
      languages: ["text"],
      metrics: null,
      selectedPaths: action.keepSelection ? state.selectedPaths : EMPTY_SELECTION,
      selectionAnchor: action.keepSelection ? state.selectionAnchor : null,
      status: action.status,
      treeSource: null,
    };
  case "remove-comment": {
    const comments = state.comments.filter((comment) => comment.id !== action.id);
    return {
      ...state,
      comments,
      items: applyCommentAnnotations(state.items, comments, state.draft),
    };
  }
  case "rename-item":
    return {
      ...state,
      activeItemId: state.activeItemId === action.oldId ? action.newId : state.activeItemId,
      draft: state.draft?.itemId === action.oldId
        ? { ...state.draft, itemId: action.newId }
        : state.draft,
      items: state.items.map((item) => (
        item.id === action.oldId || item.id === action.newId
          ? { ...item, id: action.newId, version: (item.version ?? 0) + 1 }
          : item
      )),
    };
  case "select-paths": {
    const selectedPaths = setPathsSelected(state.selectedPaths, action.paths, action.selected);
    const selectionAnchor = action.anchor ?? state.selectionAnchor;
    if (selectedPaths === state.selectedPaths && selectionAnchor === state.selectionAnchor) {
      return state;
    }
    return { ...state, selectedPaths, selectionAnchor };
  }
  case "set-active-item":
    return {
      ...state,
      activeItemId: action.itemId,
      activeTreePath: action.treePath ?? state.activeTreePath,
    };
  case "replace-comments":
    return {
      ...state,
      comments: action.comments,
      draft: null,
      items: applyCommentAnnotations(state.items, action.comments, null),
    };
  case "set-copy-feedback":
    return { ...state, copyFeedback: action.message };
  case "set-draft":
    return {
      ...state,
      draft: action.draft,
      items: applyCommentAnnotations(state.items, state.comments, action.draft),
    };
  case "set-file-search-open":
    return { ...state, fileSearchOpen: action.open, filesVisible: action.open ? true : state.filesVisible };
  case "request-file-search":
    return { ...state, fileSearchOpen: true, fileSearchRequest: state.fileSearchRequest + 1, filesVisible: true };
  case "set-find-open":
    // The query is kept when closing so reopening recovers the last search.
    return { ...state, findOpen: action.open };
  case "set-find-query":
    return { ...state, findQuery: action.query };
  case "request-find":
    return { ...state, findOpen: true, findRequest: state.findRequest + 1 };
  case "set-files-width":
    return { ...state, filesWidth: action.width };
  case "set-files-visible":
    return { ...state, filesVisible: action.visible };
  case "set-metrics":
    return {
      ...state,
      metrics: action.metrics,
      selectedPaths: pruneSelectionToStream(state.selectedPaths, state.treeSource, action.metrics),
    };
  case "set-option":
    if (action.key === "collapsed") {
      // Collapse all / expand all is the new baseline: per-file choices made
      // before it are dropped so every card follows it.
      return {
        ...state,
        fileCollapseOverrides: new Map(),
        options: { ...state.options, collapsed: Boolean(action.value) },
        items: state.items.map((item) => ({
          ...item,
          collapsed: Boolean(action.value),
          version: (item.version ?? 0) + 1,
        })),
      };
    }
    return { ...state, options: { ...state.options, [action.key]: action.value } };
  case "set-options-open":
    return { ...state, optionsOpen: action.open };
  case "set-status":
    return { ...state, status: action.status };
  case "set-tree-source": {
    const source = action.source;
    const nextPath = state.activeItemId ? source.treePathByItemId.get(state.activeItemId) ?? state.activeTreePath : state.activeTreePath;
    return {
      ...state,
      activeTreePath: nextPath,
      selectedPaths: pruneSelectionToStream(state.selectedPaths, source, state.metrics),
      treeSource: source,
    };
  }
  case "toggle-item-collapsed": {
    const target = state.items.find((item) => item.id === action.itemId);
    if (!target) {
      return state;
    }
    const collapsed = target.collapsed !== true;
    const fileCollapseOverrides = new Map(state.fileCollapseOverrides);
    fileCollapseOverrides.set(fileCollapseKey(target), collapsed);
    return {
      ...state,
      fileCollapseOverrides,
      items: state.items.map((item) => (
        item.id === action.itemId
          ? { ...item, collapsed, version: (item.version ?? 0) + 1 }
          : item
      )),
    };
  }
  case "toggle-selected-path":
    return {
      ...state,
      selectedPaths: toggleSelectedPath(state.selectedPaths, action.path),
      selectionAnchor: action.path,
    };
  case "upsert-comment": {
    const exists = state.comments.some((comment) => comment.id === action.comment.id);
    const comments = exists
      ? state.comments.map((comment) => (comment.id === action.comment.id ? action.comment : comment))
      : [...state.comments, action.comment];
    return {
      ...state,
      comments,
      items: applyCommentAnnotations(state.items, comments, state.draft),
    };
  }
  }
}

/**
 * Once a stream has completed (`completedAt` set), the selection keeps only
 * the paths the completed tree lists: a file staged or discarded by a batch
 * action has left the view. Mid-stream the set is left alone, because the
 * paths still to come would otherwise be dropped. Returns the same set
 * when nothing changes.
 */
function pruneSelectionToStream(
  selection: FileSelection,
  treeSource: FileTreeSource | null,
  metrics: StreamMetrics | null,
): FileSelection {
  if (selection.size === 0 || treeSource == null || !streamCompleted(metrics)) {
    return selection;
  }
  return pruneSelection(selection, (path) => treeSource.pathToItemId.has(path));
}

function streamCompleted(metrics: StreamMetrics | null): boolean {
  return metrics != null && Number.isFinite(metrics.completedAt) && metrics.completedAt > 0;
}

/** The key a card's fold override is stored under: its file path. */
function fileCollapseKey(item: DiffItem): string {
  return item.fileDiff ? fileName(item.fileDiff, item.id) : item.id;
}

/** Effective fold state of an item: its per-file override, else the collapse-all option. */
function itemCollapsed(
  item: DiffItem,
  state: Pick<AppState, "fileCollapseOverrides" | "options">,
): boolean {
  return state.fileCollapseOverrides.get(fileCollapseKey(item)) ?? state.options.collapsed;
}

export function App({ config, initialStatus }: ConfigProps) {
  const payload = config.payload ?? {};
  const label = useMemo(
    () => createDiffViewerLabelResolver(payload.labels, {
      assertMissing: shouldAssertMissingLabels(),
    }),
    [payload.labels],
  );
  const appearance = resolveDiffViewerAppearance(payload.appearance);
  const transport = useDiffTransport(payload.transport);
  const [activeSessionSource, setActiveSessionSource] = useState<DiffSource | null>(
    validDiffSource(payload.sessionSource) ? payload.sessionSource : null,
  );
  const [resolvedSessionSource, setResolvedSessionSource] = useState<DiffSource | null>(activeSessionSource);
  const branchSourceByRepoRef = useRef(new Map<string, Extract<DiffSource, { kind: "branch" }>>());
  if (activeSessionSource?.kind === "branch" && !branchSourceByRepoRef.current.has(activeSessionSource.repoRoot)) {
    branchSourceByRepoRef.current.set(activeSessionSource.repoRoot, activeSessionSource);
  }
  const [activePatchURL, setActivePatchURL] = useState<string | undefined>(payload.patchURL);
  const [state, dispatch] = useReducer(reducer, initialAppState(config, initialStatus));
  const latestState = useSyncedRef(state);
  const codeViewRef = useRef<CodeViewHandle<any> | null>(null);
  const codeViewScrollTopRef = useRef(0);
  const copyFallbackRef = useRef<HTMLTextAreaElement | null>(null);
  const activeSessionRef = useRef<ActiveDiffSession | null>(null);
  const viewerContainerRef = useRef<HTMLDivElement | null>(null);
  const workerModuleURL = resolveDiffViewerAssetURL(config.assets?.workerModuleURL);
  const workerPoolOptions = createDiffWorkerPoolOptions(workerModuleURL);
  const highlighterOptions = workerHighlighterOptions(state.options, appearance, state.languages);
  const payloadRepoRoot = typeof payload.repoRoot === "string" && payload.repoRoot !== "" ? payload.repoRoot : null;
  const commentRepoRoot = diffSourceRepoRoot(resolvedSessionSource ?? activeSessionSource) ?? payloadRepoRoot;
  useEffect(() => {
    const configuredTitle =
      typeof payload.title === "string" ? payload.title.trim() : "";
    if (configuredTitle === "") {
      return;
    }

    const activeSource = resolvedSessionSource ?? activeSessionSource;
    if (activeSource?.kind === "patch") {
      document.title = configuredTitle;
      return;
    }

    const repoRoot = diffSourceRepoRoot(activeSource) ?? payloadRepoRoot;
    const repoOption = Array.isArray(payload.repoOptions)
      ? payload.repoOptions.find((option) => option?.value === repoRoot)
      : undefined;
    const repoLabel =
      typeof repoOption?.label === "string" ? repoOption.label.trim() : "";
    document.title =
      repoLabel === "" ? configuredTitle : `${configuredTitle} — ${repoLabel}`;
  }, [
    activeSessionSource,
    payload.repoOptions,
    payload.title,
    payloadRepoRoot,
    resolvedSessionSource,
  ]);
  const bridgeAvailable = diffCommentsBridgeAvailable() && commentRepoRoot != null;
  const commentLabels = resolveCommentLabels(payload);
  const comments = useDiffComments({
    bridgeAvailable,
    dispatch,
    latestState,
    repoRoot: commentRepoRoot,
  });
  const renderedCodeViewOptions = codeViewOptions(state.options, appearance);
  renderedCodeViewOptions.onGutterUtilityClick = comments.onGutterUtilityClick as any;
  const closeActiveSession = useCallback(() => {
    const activeSession = activeSessionRef.current;
    if (!transport) {
      return Promise.resolve();
    }
    if (!activeSession) {
      if (typeof payload.capabilityToken !== "string") {
        return Promise.resolve();
      }
      return closeDiffSession(transport, {
        sessionId: pendingSessionID,
        capabilityToken: payload.capabilityToken,
      });
    }
    activeSessionRef.current = null;
    return transport.request({
        method: "sessionClose",
        params: activeSession,
      })
      .then(() => {})
      .catch(() => {
        if (!activeSessionRef.current) {
          activeSessionRef.current = activeSession;
        }
      });
  }, [payload.capabilityToken, transport]);
  const rememberResolvedSessionSource = useCallback((source: DiffSource) => {
    if (source.kind === "branch") {
      branchSourceByRepoRef.current.set(source.repoRoot, source);
    }
    setResolvedSessionSource(source);
  }, []);

  // Write actions stay disabled from the click until the session reopened
  // by the reload exists again (`settleWrite`, called by the render hook), so
  // a second click can never race the reload or target the closed session.
  const [pendingWrite, setPendingWrite] = useState(false);
  const pendingWriteRef = useRef(false);
  // A settled session is also when a working-tree view's repository status
  // loads (`loadRepositoryStatusOnce`, defined with the status below).
  const loadRepositoryStatusOnceRef = useRef<() => void>(() => {});
  const settleWrite = useCallback(() => {
    pendingWriteRef.current = false;
    setPendingWrite(false);
    loadRepositoryStatusOnceRef.current();
  }, []);
  // Scroll offset to restore once the stream after a write action reload
  // completes; any other stream start clears it.
  const restoreScrollRef = useRef<number | null>(null);

  usePageDataAttributes(state);
  usePendingReplacement(payload, label, dispatch, transport);
  useRenderDiff(
    config,
    transport,
    label,
    dispatch,
    latestState,
    setActivePatchURL,
    activeSessionRef,
    closeActiveSession,
    activeSessionSource,
    rememberResolvedSessionSource,
    restoreScrollRef,
    settleWrite,
  );
  useCommentsBootstrap(bridgeAvailable ? commentRepoRoot : null, comments.onLoaded);
  const closeOptions = useCallback(() => dispatch({ type: "set-options-open", open: false }), [dispatch]);
  useDismissOnOutsideInteraction(state.optionsOpen, closeOptions, "#toolbar");
  useFileSearchDismiss(state.fileSearchOpen, dispatch);

  // Working-tree write actions: only for typed unstaged/staged sessions on a
  // sidecar that advertised `worktree.write`. Patch and branch sources never
  // show them.
  const hasTypedSession = transport != null && typeof payload.capabilityToken === "string";
  const sidecarCapabilities = useSidecarCapabilities(transport, hasTypedSession);
  const writeSource = writableDiffSource(resolvedSessionSource ?? activeSessionSource);
  const writeAvailable = worktreeWriteAvailable(writeSource, sidecarCapabilities, hasTypedSession);
  // Hunk action rows are attached at render time (cached per item) rather
  // than stored on the reducer's items, so `writeAvailable` stays the single
  // source of truth for whether they show.
  const renderedItems = useMemo(
    () => (writeAvailable ? attachHunkActionAnnotations(state.items) : state.items),
    [state.items, writeAvailable],
  );
  const [commitOpen, setCommitOpen] = useState(false);
  const [pullRequestOpen, setPullRequestOpen] = useState(false);
  const [worktreeNotice, setWorktreeNotice] = useState<WorktreeNotice | null>(null);
  const noticeTokenRef = useRef(0);
  const closeCommitPopover = useCallback(() => setCommitOpen(false), []);
  const closePullRequestPopover = useCallback(() => setPullRequestOpen(false), []);
  const expireNotice = useCallback((token: number) => {
    setWorktreeNotice((current) => (current?.token === token ? null : current));
  }, []);
  const showWorktreeNotice = (message: string, error: boolean) => {
    noticeTokenRef.current += 1;
    setWorktreeNotice({ error, message, token: noticeTokenRef.current });
  };
  // Repository status (branch, upstream, forge, pull request) loads once per
  // opened working-tree view, again after a commit, push, or pull request,
  // and on an explicit refresh; never on a timer.
  const [repositoryStatus, setRepositoryStatus] = useState<RepositoryStatus | null>(null);
  const [createdPullRequest, setCreatedPullRequest] = useState<PullRequestSummary | null>(null);
  const statusRequestRef = useRef(0);
  const refreshRepositoryStatus = useCallback(() => {
    const session = activeSessionRef.current;
    if (!transport || !writeSource || !session) {
      return;
    }
    statusRequestRef.current += 1;
    const requestId = statusRequestRef.current;
    transport
      .request(buildRepositoryStatusRequest(session, writeSource))
      .then((result) => {
        if (requestId !== statusRequestRef.current || result.type !== "repositoryStatus") {
          return;
        }
        setRepositoryStatus(result.value);
        if (result.value.pullRequest) {
          setCreatedPullRequest(null);
        }
      })
      .catch((error) => console.warn("cmux diff repository status failed", error));
  }, [transport, writeSource]);
  const statusKey = writeAvailable && writeSource ? `${writeSource.kind}\n${writeSource.repoRoot}` : null;
  const statusFetchedForRef = useRef<string | null>(null);
  // The first settled session of each working-tree view loads its status; a
  // reload after a write keeps the one already shown. Runs when a session
  // settles (`settleWrite`) and when the view changes, whichever comes last.
  const loadRepositoryStatusOnce = useCallback(() => {
    if (statusKey == null) {
      statusFetchedForRef.current = null;
      return;
    }
    if (statusFetchedForRef.current === statusKey || !activeSessionRef.current) {
      return;
    }
    statusFetchedForRef.current = statusKey;
    setRepositoryStatus(null);
    setCreatedPullRequest(null);
    refreshRepositoryStatus();
  }, [refreshRepositoryStatus, statusKey]);
  useEffect(() => {
    loadRepositoryStatusOnceRef.current = loadRepositoryStatusOnce;
    loadRepositoryStatusOnce();
  }, [loadRepositoryStatusOnce]);
  // Only a write action reload asks to restore the scroll offset; any other
  // source change drops a pending restore so it cannot fire on the stream
  // of an unrelated diff.
  const selectSessionSource = (source: DiffSource, restoreScroll = false) => {
    if (!restoreScroll) {
      restoreScrollRef.current = null;
    }
    const currentSource = resolvedSessionSource ?? activeSessionSource;
    const selectedSource = source.kind === "branch"
      && (currentSource?.kind !== "branch" || source.baseRef == null)
      ? branchSourceByRepoRef.current.get(source.repoRoot) ?? source
      : source;
    if (selectedSource.kind === "branch") {
      branchSourceByRepoRef.current.set(selectedSource.repoRoot, selectedSource);
    }
    const status = createDiffViewerStatus(label("loadingDiff"), { pending: true });
    applyDiffViewerStatusToDocument(status);
    dispatch({ type: "reset-diff", status, keepSelection: restoreScroll });
    setActivePatchURL(undefined);
    void closeActiveSession();
    setResolvedSessionSource(selectedSource);
    setActiveSessionSource(selectedSource);
  };
  // After a mutation the session is reopened in place (no page reload). The
  // scroll offset is carried across the reload; the collapse-all option and
  // the per-file fold overrides survive the reset on their own.
  const reloadAfterWrite = (source: WritableDiffSource) => {
    restoreScrollRef.current = codeViewScrollTopRef.current;
    selectSessionSource({ ...source }, true);
  };
  // The host's in-place refresh (`window.cmuxDiffViewer.refresh()`, called
  // through evaluateJavaScript): the same session reopen a write action uses,
  // so the scroll offset, the per-file folds, and the repository status
  // already shown all stay put and nothing is refetched. Only an open
  // working-tree session can take it, and never while a write is in flight;
  // on `false` the host falls back to a full document reload. The reload
  // holds the write actions until the reopened session exists, exactly as a
  // write does, so a click cannot target the closing session.
  const refreshInPlace = (): boolean => {
    if (!writeSource || pendingWriteRef.current || !activeSessionRef.current) {
      return false;
    }
    pendingWriteRef.current = true;
    setPendingWrite(true);
    reloadAfterWrite(writeSource);
    return true;
  };
  useHostRefresh(useSyncedRef(refreshInPlace));
  const runWorktreeWrite = async (command: DiffCommand, source: WritableDiffSource) => {
    if (!transport || pendingWriteRef.current) {
      return;
    }
    pendingWriteRef.current = true;
    setPendingWrite(true);
    let reloading = false;
    try {
      const result = await transport.request(command);
      if (result.type === "committed") {
        // Reload first: the commit exists whatever the response carries. The
        // reopened session refetches the status (the branch moved ahead).
        reloading = true;
        statusFetchedForRef.current = null;
        reloadAfterWrite(source);
        const commit: unknown = result.value?.commit;
        const shortCommit = typeof commit === "string" ? commit.slice(0, 10) : "";
        showWorktreeNotice(formatLabel(label("committed"), { commit: shortCommit }).trim(), false);
        setCommitOpen(false);
      } else if (result.type === "worktreeMutated") {
        reloading = true;
        reloadAfterWrite(source);
      } else if (result.type === "pushed") {
        const { branch, remote, upstreamCreated } = result.value;
        showWorktreeNotice(
          formatLabel(label(upstreamCreated ? "pushedUpstreamCreated" : "pushed"), { branch, remote }),
          false,
        );
        refreshRepositoryStatus();
      } else if (result.type === "pullRequestCreated") {
        const created = result.value;
        setCreatedPullRequest({
          number: created.number,
          url: created.url,
          title: created.title,
          state: "open",
          isDraft: created.isDraft,
          baseBranch: "",
        });
        setPullRequestOpen(false);
        showWorktreeNotice(formatLabel(label("pullRequestCreated"), { number: created.number }), false);
        refreshRepositoryStatus();
      } else {
        throw new DiffTransportError("invalidResponse", "Diff transport did not confirm the change");
      }
    } catch (error) {
      const transportError = error instanceof DiffTransportError ? error : null;
      const code = transportError?.code;
      const detail = worktreeErrorDetail(code, error instanceof Error ? error.message : undefined);
      const summary = label(worktreeErrorLabelKey(code));
      showWorktreeNotice(detail ? `${summary} ${detail}` : summary, true);
      if (worktreeErrorReloads(code, transportError?.stateMayHaveChanged)) {
        reloading = true;
        reloadAfterWrite(source);
      }
    } finally {
      // A reload keeps the actions disabled until the reopened session
      // exists; the render hook settles it then.
      if (!reloading) {
        settleWrite();
      }
    }
  };
  // The session a write targets. The actions render only for an open typed
  // session, so a missing one means the page is between sessions.
  const writeSession = () => {
    const session = activeSessionRef.current;
    if (!session) {
      showWorktreeNotice(label("worktreeWriteFailed"), true);
    }
    return session;
  };
  const onFileWriteAction = (item: DiffItem, action: FileWriteAction) => {
    const target = worktreeFileTarget(item.fileDiff);
    const session = writeSession();
    if (!writeSource || !session || !target) {
      return;
    }
    void runWorktreeWrite(buildFileRequest(action, session, writeSource, target), writeSource);
  };
  const onHunkRevert = (item: DiffItem, hunk: HunkRef) => {
    const target = worktreeFileTarget(item.fileDiff);
    const session = writeSession();
    if (!writeSource || !session || !target) {
      return;
    }
    void runWorktreeWrite(buildHunkRequest(session, writeSource, target, hunk), writeSource);
  };
  const onCommit = (message: string, stageAll: boolean) => {
    const session = writeSession();
    if (!writeSource || !session) {
      return;
    }
    void runWorktreeWrite(buildCommitRequest(session, writeSource, message, stageAll), writeSource);
  };
  const onBulkAction = (action: BulkWriteAction) => {
    const session = writeSession();
    if (!writeSource || !session) {
      return;
    }
    void runWorktreeWrite(buildBulkRequest(action, session, writeSource), writeSource);
  };
  // The checked files, as item ids: only paths the stream has produced so
  // far count (the stored set is pruned once a reload completes). The
  // header's count, the cards' checkboxes, and the selection actions all
  // read this one set.
  const pathToItemId = state.treeSource?.pathToItemId;
  const selectedItemIds = useMemo(() => {
    const ids = new Set<string>();
    if (!pathToItemId) {
      return ids;
    }
    for (const path of state.selectedPaths) {
      const itemId = pathToItemId.get(path);
      if (itemId) {
        ids.add(itemId);
      }
    }
    return ids;
  }, [pathToItemId, state.selectedPaths]);
  // One sidecar call for the whole selection (`worktreeStageFiles`,
  // `worktreeUnstageFiles`, `worktreeDiscardFiles`); the reload afterwards
  // drops the acted-on paths from the selection as they leave the view.
  const onSelectionAction = (action: SelectionWriteAction) => {
    const targets = selectedFileTargets(state.items, selectedItemIds);
    const session = writeSession();
    if (!writeSource || !session || targets.length === 0) {
      return;
    }
    void runWorktreeWrite(buildFilesRequest(action, session, writeSource, targets), writeSource);
  };
  const clearSelection = () => dispatch({ type: "clear-selection" });
  // A push from the header always creates a missing upstream: the button is
  // the user's answer to "push where?", and the status line shows the result.
  const onPush = () => {
    const session = writeSession();
    if (!writeSource || !session) {
      return;
    }
    void runWorktreeWrite(buildPushRequest(session, writeSource, true), writeSource);
  };
  const onCreatePullRequest = (draft: PullRequestDraft) => {
    const session = writeSession();
    if (!writeSource || !session) {
      return;
    }
    void runWorktreeWrite(buildCreatePullRequestRequest(session, writeSource, draft), writeSource);
  };
  // "Open in cmux" is a host action: only the WebKit transport can carry it,
  // and the host re-validates the path against the token's repositories.
  const requestHost = transport?.requestHost?.bind(transport);
  const onOpenInCmux = requestHost && writeSource
    ? (item: DiffItem) => {
        const target = worktreeFileTarget(item.fileDiff);
        const token = activeSessionRef.current?.capabilityToken;
        if (!target || !token) {
          return;
        }
        requestHost(buildOpenFileRequest(token, target)).catch(() => {
          showWorktreeNotice(label("openInCmuxFailed"), true);
        });
      }
    : undefined;
  const onCopyPath = (item: DiffItem) => {
    const target = worktreeFileTarget(item.fileDiff);
    if (!target) {
      return;
    }
    copyText(target.path, copyFallbackRef.current).then(
      () => dispatch({ type: "set-copy-feedback", message: label("copiedPath") }),
      () => dispatch({ type: "set-copy-feedback", message: label("copyPathFailed") }),
    );
  };
  const copyGitApply = async () => {
    try {
      const message = await copyGitApplyCommand(activePatchURL, label, copyFallbackRef.current);
      dispatch({ type: "set-copy-feedback", message });
    } catch {
      dispatch({ type: "set-copy-feedback", message: label("copyFailedGitApplyCommand") });
    }
  };
  const reloadPage = async () => {
    await closeActiveSession();
    window.location.reload();
  };
  // One condition decides the top row: a working-tree view whose source can
  // be committed shows the repository header (with its commit control), and
  // every other session shows the toolbar.
  const availability = commitAvailability(writeSource);
  const header = writeAvailable && writeSource != null && availability !== "hidden"
    ? { availability, source: writeSource }
    : null;
  const pullRequestControl = {
    current: repositoryStatus?.pullRequest ?? createdPullRequest,
    onClose: closePullRequestPopover,
    onCreate: onCreatePullRequest,
    onToggle: () => {
      setCommitOpen(false);
      setPullRequestOpen((open) => !open);
    },
    open: pullRequestOpen,
  };


  const renderCommentAnnotation = (annotation: CommentAnnotation, item: DiffItem) => {
    const metadata = annotation.metadata;
    if (metadata.kind === "hunkActions") {
      return (
        <HunkWriteActions
          label={label}
          onRevert={() => onHunkRevert(item, metadata.hunk)}
          pending={pendingWrite}
        />
      );
    }
    if (metadata.kind === "draft") {
      return (
        <CommentComposer
          labels={commentLabels}
          onCancel={() => dispatch({ type: "set-draft", draft: null })}
          onSave={(message) => comments.saveDraft(item, message)}
        />
      );
    }
    return (
      <SavedComment
        comment={metadata.comment}
        labels={commentLabels}
        onDelete={() => comments.remove(metadata.comment)}
        onSaveMessage={(message) => comments.editMessage(metadata.comment, message, item.fileDiff)}
      />
    );
  };

  const diffStreamComplete = Number.isFinite(state.metrics?.completedAt) && (state.metrics?.completedAt ?? 0) > 0;
  useEffect(() => {
    if (!diffStreamComplete || restoreScrollRef.current == null) {
      return;
    }
    const position = restoreScrollRef.current;
    restoreScrollRef.current = null;
    const frame = requestAnimationFrame(() => {
      codeViewRef.current?.scrollTo({ type: "position", position, behavior: "instant" });
    });
    return () => cancelAnimationFrame(frame);
  }, [diffStreamComplete]);
  const commentEntries = sidebarCommentEntries(state.items, state.comments, diffStreamComplete);
  const selectCommentEntry = (entry: SidebarCommentEntry) => {
    if (entry.itemId == null) {
      return;
    }
    if (entry.anchor.state === "outdated") {
      codeViewRef.current?.scrollTo({ type: "item", id: entry.itemId, align: "start", behavior: "smooth-auto" });
    } else {
      codeViewRef.current?.scrollTo({
        type: "line",
        id: entry.itemId,
        lineNumber: entry.anchor.line,
        side: entry.comment.side,
        align: "center",
        behavior: "smooth-auto",
      });
    }
    dispatch({
      type: "set-active-item",
      itemId: entry.itemId,
      treePath: state.treeSource?.treePathByItemId.get(entry.itemId),
    });
  };

  const selectedTreePath = state.treeSource?.treePathByItemId.get(state.activeItemId) ?? state.activeTreePath;
  const scrollToItem = useCallback((itemId: string) => {
    const current = latestState.current;
    const target = scrollTargetForItem(itemId, current.items);
    if (!target) {
      return;
    }
    codeViewRef.current?.scrollTo({ type: "item", id: target, align: "start", behavior: "smooth-auto" });
    dispatch({
      type: "set-active-item",
      itemId: target,
      treePath: current.treeSource?.treePathByItemId.get(target),
    });
  }, [latestState]);
  const jumpAdjacentFile = useCallback((direction: -1 | 1) => {
    const current = latestState.current;
    const visibleItem = visibleItemId(
      current.items,
      codeViewScrollTopRef.current,
      (itemId) => codeViewRef.current?.getInstance()?.getTopForItem(itemId),
    );
    const target = adjacentItemId(visibleItem || current.activeItemId, current.items, direction);
    if (target) {
      scrollToItem(target);
    }
  }, [latestState, scrollToItem]);
  const handleCodeViewScroll = useCallback((scrollTop: number) => {
    codeViewScrollTopRef.current = scrollTop;
  }, []);
  const find = useDiffFind({
    items: state.items,
    open: state.findOpen,
    query: state.findQuery,
    dispatch,
    codeViewRef,
    viewerContainerRef,
  });
  const findBridgeRef = useSyncedRef({ open: state.findOpen, controller: find });
  useFindKeyboard(dispatch, findBridgeRef);
  useNativeViewerNavigation(viewerContainerRef, dispatch, jumpAdjacentFile, findBridgeRef);
  const setStatus = (status: DiffViewerStatus) => {
    applyDiffViewerStatusToDocument(status);
    dispatch({ type: "set-status", status });
  };
  const setLayout = (layout: DiffViewerLayout) => {
    persistDiffViewerLayout(layout);
    dispatch({ type: "set-option", key: "layout", value: layout });
  };

  const navigateTo = (url: string) => {
    setStatus(createDiffViewerStatus(label("loadingDiff"), { pending: true }));
    // Session cleanup is best-effort and can wait on WebKit's reply path.
    // Do not make source/repository/base selection wait for it: navigation
    // starts a new typed session and must stay responsive.
    void closeActiveSession();
    window.location.href = resolveDiffNavigationURL(url);
  };
  // Working-tree views render the repository header as their single top
  // row: it hosts the source/repo/base pickers, the branch and totals, the
  // split button, the files-list toggle, and the one "..." menu (repo actions
  // plus every view option). The toolbar renders only for every other
  // session, so the pickers and the view options each come from exactly one
  // place. Picker ids stay put for the tests and CSS that address them.
  const externalURL = resolveExternalURL(payload);
  const sourceControls = (
    <SourceControls
      activeSessionSource={resolvedSessionSource ?? activeSessionSource}
      className={header != null ? "repo-header-source" : "toolbar-left"}
      label={label}
      onNavigate={navigateTo}
      onSelectSessionSource={(source) => selectSessionSource(source)}
      payload={payload}
      transport={transport}
    />
  );

  return (
    <div id="app" data-file-search-open={state.fileSearchOpen}>
      {header != null ? (
        <RepositoryHeader
          commit={{
            availability: header.availability,
            onClose: closeCommitPopover,
            onCommit,
            onToggle: () => {
              setPullRequestOpen(false);
              setCommitOpen((open) => !open);
            },
            open: commitOpen,
          }}
          label={label}
          model={repositoryHeaderModel(header.source, repositoryStatus, state.treeSource?.diffStats, payloadRepoLabel(payload, header.source))}
          notice={worktreeNotice}
          onBulkAction={onBulkAction}
          onCopyGitApply={copyGitApply}
          onNoticeExpire={expireNotice}
          onPush={onPush}
          onRefresh={reloadPage}
          pending={pendingWrite}
          pullRequest={pullRequestControl}
          selection={{ count: selectedItemIds.size, onAction: onSelectionAction, onClear: clearSelection }}
          files={{
            onToggle: () => dispatch({ type: "set-files-visible", visible: !state.filesVisible }),
            visible: state.filesVisible,
          }}
          showRepoLabel={!hasRepoSelect(payload)}
          source={header.source}
          sourceControls={sourceControls}
          status={repositoryStatus}
          viewOptions={
            <ViewOptionsMenuItems
              dispatch={dispatch}
              externalURL={externalURL}
              filesVisible={state.filesVisible}
              label={label}
              onSetLayout={setLayout}
              options={state.options}
            />
          }
        />
      ) : (
        <Toolbar
          config={config}
          externalURL={externalURL}
          label={label}
          onCopyGitApply={copyGitApply}
          onReload={reloadPage}
          onSetLayout={setLayout}
          sourceControls={sourceControls}
          dispatch={dispatch}
          state={state}
        />
      )}
      <section id="content" style={{ "--cmux-diff-files-width": `${state.filesWidth}px` } as React.CSSProperties}>
        <FilesSidebarBackdrop
          label={label}
          onClose={() => closeFileSearch(dispatch)}
          open={state.fileSearchOpen}
        />
        <FilesSidebar
          commentEntries={commentEntries}
          commentLabels={commentLabels}
          hasDraft={state.draft != null}
          label={label}
          onSelectComment={selectCommentEntry}
          onSelectItem={scrollToItem}
          selectable={header != null}
          selectedPath={selectedTreePath}
          dispatch={dispatch}
          state={state}
        />
        <main id="viewer" aria-label={label("diffViewer")}>
          {state.findOpen ? (
            <FindBar
              controller={find}
              label={label}
              query={state.findQuery}
              requestToken={state.findRequest}
            />
          ) : null}
          {state.items.length > 0 ? (
            <WorkerPoolContextProvider
              poolOptions={workerPoolOptions}
              highlighterOptions={highlighterOptions}
            >
              <WorkerRenderOptionsSync codeViewRef={codeViewRef} highlighterOptions={highlighterOptions} />
              <CodeView
                ref={codeViewRef}
                className="code-view-root"
                containerRef={viewerContainerRef}
                items={renderedItems}
                onScroll={handleCodeViewScroll}
                options={renderedCodeViewOptions}
                renderHeaderPrefix={(item) => (
                  <>
                    <FileCollapseToggle
                      collapsed={(item as DiffItem).collapsed === true}
                      label={label}
                      onToggle={() => dispatch({ type: "toggle-item-collapsed", itemId: item.id })}
                    />
                    {header != null ? (
                      <FileSelectCheckbox
                        checked={selectedItemIds.has(item.id)}
                        label={formatLabel(label("selectFile"), { name: fileCollapseKey(item as DiffItem) })}
                        onToggle={() => dispatch({
                          type: "toggle-selected-path",
                          path: state.treeSource?.treePathByItemId.get(item.id) ?? fileCollapseKey(item as DiffItem),
                        })}
                      />
                    ) : null}
                  </>
                )}
                renderHeaderMetadata={(item) => (
                  <>
                    {writeAvailable ? (
                      <FileWriteActions
                        actions={fileActionsForSource(writeSource)}
                        label={label}
                        onAction={(action) => onFileWriteAction(item as DiffItem, action)}
                        onCopyPath={() => onCopyPath(item as DiffItem)}
                        onOpenInCmux={onOpenInCmux ? () => onOpenInCmux(item as DiffItem) : undefined}
                        pending={pendingWrite}
                      />
                    ) : null}
                    <DiffHeaderMetadata fileDiff={(item as DiffItem).fileDiff} label={label} />
                  </>
                )}
                renderAnnotation={(annotation, item) =>
                  renderCommentAnnotation(annotation as CommentAnnotation, item as DiffItem)}
              />
            </WorkerPoolContextProvider>
          ) : null}
        </main>
        <LoadingLayer label={label} status={state.status} />
      </section>
      <textarea
        ref={copyFallbackRef}
        aria-hidden="true"
        readOnly
        tabIndex={-1}
        className="copy-fallback-textarea"
      />
      {/* Copy results are announced from the page itself: the header's copy
          path action and the menus' copy command both report here, whether
          the toolbar renders or not. */}
      <span id="copy-feedback" className="visually-hidden" aria-live="polite">
        {state.copyFeedback}
      </span>
    </div>
  );
}

export function FilesSidebarBackdrop({
  label,
  onClose,
  open,
}: {
  label: DiffViewerLabelResolver;
  onClose: () => void;
  open: boolean;
}) {
  if (!open) {
    return null;
  }
  return (
    <button
      id="files-sidebar-backdrop"
      type="button"
      aria-controls="files-sidebar"
      aria-label={label("hideFileSearch")}
      title={label("hideFileSearch")}
      onClick={onClose}
    />
  );
}

function resolveDiffViewerAssetURL(rawURL: string | undefined): URL {
  return new URL(rawURL || defaultWorkerModuleURL, window.location.href);
}

/**
 * Bundles the diff comment handlers: loading persisted comments, opening a
 * draft from the gutter utility, and saving/editing/deleting. Saved comments
 * carry a precomputed `submissionText`; native code pools them per workspace
 * and consumes the pool on TextBox submit.
 */
function useDiffComments({
  bridgeAvailable,
  dispatch,
  latestState,
  repoRoot,
}: {
  bridgeAvailable: boolean;
  dispatch: React.Dispatch<AppAction>;
  latestState: React.MutableRefObject<AppState>;
  repoRoot: string | null;
}) {
  const activeRepoRoot = useSyncedRef(repoRoot);
  const onLoaded = useCallback(
    (comments: DiffCommentRecord[]) => dispatch({ type: "replace-comments", comments }),
    [dispatch],
  );

  const onGutterUtilityClick = (range: SelectedLineRange, context: { item: DiffItem }) => {
    const side: DiffCommentSide = range.side === "deletions" ? "deletions" : "additions";
    dispatch({
      type: "set-draft",
      draft: {
        itemId: context.item.id,
        side,
        startLine: Math.min(range.start, range.end),
        endLine: Math.max(range.start, range.end),
      },
    });
  };

  const saveDraft = (item: DiffItem, message: string) => {
    const draft = latestState.current.draft;
    if (draft == null || draft.itemId !== item.id || message.trim() === "") {
      return;
    }
    const input = {
      filePath: fileName(item.fileDiff, ""),
      side: draft.side,
      startLine: draft.startLine,
      endLine: draft.endLine,
      lineText: lineTextFor(item.fileDiff, draft.side, draft.endLine) ?? "",
      message,
    };
    const record = { ...input, submissionText: commentSubmissionText(input, item.fileDiff) };
    const save = bridgeAvailable && repoRoot != null
      ? bridgeSaveComment(repoRoot, record)
      : Promise.resolve(localCommentRecord(record));
    save
      .then((saved) => {
        if (activeRepoRoot.current !== repoRoot) {
          return;
        }
        dispatch({ type: "upsert-comment", comment: saved });
        dispatch({ type: "set-draft", draft: null });
      })
      .catch((error) => console.warn("cmux diff comment save failed", error));
  };

  const editMessage = (
    comment: DiffCommentRecord,
    message: string,
    fileDiff: CommentFileDiff | null | undefined,
  ) => {
    if (message.trim() === "") {
      return;
    }
    const edited = { ...comment, message, updatedAt: new Date().toISOString() };
    const updated = { ...edited, submissionText: commentSubmissionText(edited, fileDiff) };
    const save = bridgeAvailable && repoRoot != null
      ? bridgeSaveComment(repoRoot, updated)
      : Promise.resolve(updated);
    save
      .then((saved) => {
        if (activeRepoRoot.current === repoRoot) {
          dispatch({ type: "upsert-comment", comment: saved });
        }
      })
      .catch((error) => console.warn("cmux diff comment edit failed", error));
  };

  const remove = (comment: DiffCommentRecord) => {
    const targetRepoRoot = repoRoot;
    if (bridgeAvailable && repoRoot != null) {
      bridgeDeleteComment(repoRoot, comment.id)
        .catch((error) => console.warn("cmux diff comment delete failed", error));
    }
    if (activeRepoRoot.current === targetRepoRoot) {
      dispatch({ type: "remove-comment", id: comment.id });
    }
  };

  return { editMessage, onGutterUtilityClick, onLoaded, remove, saveDraft };
}

function localCommentRecord(
  input: Omit<DiffCommentRecord, "id" | "createdAt" | "updatedAt">,
): DiffCommentRecord {
  const now = new Date().toISOString();
  return { ...input, id: crypto.randomUUID(), createdAt: now, updatedAt: now };
}

function initialDiffViewerLayout(payload: Record<string, any>): DiffViewerLayout {
  const payloadLayout = parseDiffViewerLayout(payload.layout);
  if (payload.layoutSource === "explicit" && payloadLayout) {
    return payloadLayout;
  }
  return readPersistedDiffViewerLayout() ?? payloadLayout ?? "unified";
}

function readPersistedDiffViewerLayout(): DiffViewerLayout | null {
  try {
    return parseDiffViewerLayout(window.localStorage.getItem(persistedLayoutKey));
  } catch {
    return null;
  }
}

function persistDiffViewerLayout(layout: DiffViewerLayout): void {
  try {
    window.localStorage.setItem(persistedLayoutKey, layout);
  } catch {
    // Storage may be unavailable for some generated viewer origins.
  }
}

function parseDiffViewerLayout(value: unknown): DiffViewerLayout | null {
  return value === "split" || value === "unified" ? value : null;
}

function WorkerRenderOptionsSync({
  codeViewRef,
  highlighterOptions,
}: {
  codeViewRef: React.MutableRefObject<CodeViewHandle<any> | null>;
  highlighterOptions: ReturnType<typeof workerHighlighterOptions>;
}) {
  useWorkerRenderOptionsSync(highlighterOptions, codeViewRef);
  return null;
}

function Toolbar({
  config,
  dispatch,
  externalURL,
  label,
  onCopyGitApply,
  onReload,
  onSetLayout,
  sourceControls,
  state,
}: {
  config: DiffViewerConfig;
  dispatch: React.Dispatch<AppAction>;
  externalURL: string | null;
  label: DiffViewerLabelResolver;
  onCopyGitApply: () => void;
  onReload: () => void;
  onSetLayout: (layout: DiffViewerLayout) => void;
  /** The source/repo/base pickers; the App renders them from exactly one host. */
  sourceControls: React.ReactNode;
  state: AppState;
}) {
  const payload = config.payload ?? {};
  const toolbarRef = useRef<HTMLElement>(null);
  const toolbarWidth = useToolbarWidth(toolbarRef);
  // Optional ACCESSORY controls, HIGH priority first (last = first to overflow).
  // Drop order at narrowing: external link -> layout toggle -> files toggle. Each
  // has a canonical copy in the "..." menu, so overflowing one only hides its
  // duplicate bar icon and it stays reachable from the menu. The source select,
  // repo select, and Base picker are NOT in this list: they are always rendered
  // in the bar (a native <select> has no menu equivalent, so the repo select must
  // never be dropped — it shrinks/ellipsizes in place instead). Estimated widths
  // include each control's ~4px inter-item gap.
  const overflowItems = [
    { id: "files-toggle" as const, width: TOOLBAR_ICON_SLOT },
    { id: "layout-toggle" as const, width: TOOLBAR_ICON_SLOT },
    ...(externalURL ? [{ id: "external-link" as const, width: TOOLBAR_ICON_SLOT }] : []),
  ];
  const overflow =
    toolbarWidth == null
      ? new Set<string>()
      : new Set(
          resolveToolbarOverflow({
            available: toolbarWidth,
            // Always-present zone: source select + repo select + Base picker +
            // "..." button + horizontal padding. Generous so we shed before, not
            // after, overlap; the CSS clip covers any residual under-estimate. The
            // repo select is always in the bar now, so reserve its slot too (it
            // shrinks in place rather than overflowing).
            reserved: TOOLBAR_ALWAYS_PRESENT_WIDTH + (hasRepoSelect(payload) ? TOOLBAR_REPO_SELECT_MIN : 0),
            items: overflowItems,
          }).overflow,
        );
  const showFilesToggle = !overflow.has("files-toggle");
  const showLayoutToggle = !overflow.has("layout-toggle");
  const showExternalLink = externalURL != null && !overflow.has("external-link");
  return (
    <header id="toolbar" ref={toolbarRef}>
      {sourceControls}
      <div className="toolbar-actions flex items-center gap-1.5">
        {showExternalLink ? (
          <a
            id="external-link"
            className="toolbar-icon"
            href={externalURL ?? undefined}
            target="_blank"
            rel="noreferrer"
            title={label("openSourceURL")}
            aria-label={label("openSourceURL")}
          >
            <Icon name="external" />
          </a>
        ) : null}
        {showLayoutToggle ? (
          <button
            id="layout-toggle"
            className="toolbar-icon"
            type="button"
            title={state.options.layout === "split" ? label("switchToUnifiedDiff") : label("switchToSplitDiff")}
            aria-label={state.options.layout === "split" ? label("switchToUnifiedDiff") : label("switchToSplitDiff")}
            onClick={() => onSetLayout(state.options.layout === "split" ? "unified" : "split")}
          >
            <Icon name={state.options.layout} />
          </button>
        ) : null}
        <button
          id="options-button"
          className="toolbar-icon"
          type="button"
          title={label("options")}
          aria-label={label("options")}
          aria-expanded={state.optionsOpen}
          aria-controls="options-menu"
          onClick={() => dispatch({ type: "set-options-open", open: !state.optionsOpen })}
        >
          <Icon name="dots" />
        </button>
        {showFilesToggle ? (
          <button
            id="files-toggle"
            className="toolbar-icon"
            type="button"
            title={state.filesVisible ? label("hideFiles") : label("showFiles")}
            aria-label={state.filesVisible ? label("hideFiles") : label("showFiles")}
            aria-pressed={state.filesVisible}
            onClick={() => dispatch({ type: "set-files-visible", visible: !state.filesVisible })}
          >
            <Icon name="files" />
          </button>
        ) : null}
      </div>
      {state.optionsOpen ? (
        <OptionsMenu
          dispatch={dispatch}
          externalURL={externalURL}
          label={label}
          onCopyGitApply={onCopyGitApply}
          onReload={onReload}
          onSetLayout={onSetLayout}
          state={state}
        />
      ) : null}
    </header>
  );
}

// Pixel slot for one toolbar-actions icon button: 20px control + ~8px gap. The
// resolver only uses these as relative estimates; the CSS `overflow: clip` on
// the toolbar cells is the hard no-overlap guarantee, so exactness is not load
// bearing.
const TOOLBAR_ICON_SLOT = 28;
// Width reserved for the always-present zone (source select + Base picker + the
// "..." button + horizontal padding/gaps). Deliberately generous: the optional
// controls shed early rather than allowing the always-present zone to overflow.
const TOOLBAR_ALWAYS_PRESENT_WIDTH = 248;
// Min width the always-present repo select can shrink to (its CSS `min-width`
// floor of 56px + ~4px gap). It ellipsizes in place down to this floor rather
// than overflowing, so reserve only the floor, not its full natural width.
const TOOLBAR_REPO_SELECT_MIN = 60;

function resolveExternalURL(payload: any): string | null {
  return typeof payload?.externalURL === "string" && payload.externalURL.length > 0 ? payload.externalURL : null;
}

function hasRepoSelect(payload: any): boolean {
  return Array.isArray(payload?.repoOptions) && payload.repoOptions.length >= 2;
}

function SourceControls({
  activeSessionSource,
  className,
  label,
  onNavigate,
  onSelectSessionSource,
  payload,
  transport,
}: {
  activeSessionSource: DiffSource | null;
  /** `toolbar-left` in the toolbar, `repo-header-source` in the repository header. */
  className: string;
  label: DiffViewerLabelResolver;
  onNavigate: (url: string) => void;
  onSelectSessionSource: (source: DiffSource) => void;
  payload: any;
  transport: DiffTransport | null;
}) {
  return (
    <div className={`${className} flex min-w-0 items-center gap-1.5`}>
      <NavigationSelect
        ariaLabel={label("diffTarget")}
        fallbackValue=""
        id="source-select"
        options={payload.sourceOptions}
        onNavigate={onNavigate}
        onSelectSessionSource={(source) => onSelectSessionSource(
          sourceSelectionWithActiveRepo(source, activeSessionSource),
        )}
        selectedValue={diffSourceKind(activeSessionSource)}
      />
      {/* The repo select is ALWAYS rendered (a native <select> has no "..." menu
          equivalent, so dropping it would strand multi-repo users). It shrinks
          and ellipsizes in place via field-sizing + the .toolbar-left clip. */}
      {activeSessionSource?.kind !== "patch" ? (
        <NavigationSelect
          ariaLabel={label("repoPath")}
          fallbackValue={payload.repoRoot ?? ""}
          id="repo-select"
          options={payload.repoOptions}
          onNavigate={onNavigate}
          onSelectSessionSource={(source) => onSelectSessionSource(
            repoSelectionWithActiveSource(source, activeSessionSource),
          )}
          selectedOptionTitle
          selectedValue={diffSourceRepoRoot(activeSessionSource)}
        />
      ) : null}
      <BaseControl
        activeSessionSource={activeSessionSource}
        label={label}
        onNavigate={onNavigate}
        onSelectSessionSource={onSelectSessionSource}
        payload={payload}
        transport={transport}
      />
    </div>
  );
}

/**
 * Renders the searchable Base button+popover when the backend supplies
 * `payload.branchPicker` (FROZEN CONTRACT). Falls back to the legacy capped
 * `<select>` for older backends that only send `payload.baseOptions`.
 */
function BaseControl({
  activeSessionSource,
  label,
  onNavigate,
  onSelectSessionSource,
  payload,
  transport,
}: {
  activeSessionSource: DiffSource | null;
  label: DiffViewerLabelResolver;
  onNavigate: (url: string) => void;
  onSelectSessionSource: (source: DiffSource) => void;
  payload: any;
  transport: DiffTransport | null;
}) {
  if (activeSessionSource?.kind === "branch" && transport) {
    const typedPicker: BranchPickerPayload = {
      repoRoot: activeSessionSource.repoRoot,
      capabilityToken: payload.capabilityToken,
      headRef: "HEAD",
      currentRef: activeSessionSource.baseRef ?? "",
      currentReason: "",
      confidence: "high",
      aheadBehind: null,
      refsURL: "typed://branch-list",
      regenerateURLTemplate: "typed://branch-change/{ref}",
    };
    return (
      <BranchBasePicker
        key={branchPickerStateKey(typedPicker)}
        label={label}
        onNavigate={onNavigate}
        onSelectBranchBase={(baseRef) => onSelectSessionSource({
          kind: "branch",
          repoRoot: activeSessionSource.repoRoot,
          baseRef,
        })}
        picker={typedPicker}
        transport={transport}
      />
    );
  }
  const picker = resolveBranchPicker(payload);
  if (picker) {
    return (
      <BranchBasePicker
        key={branchPickerStateKey(picker)}
        label={label}
        onNavigate={onNavigate}
        picker={picker}
        transport={transport}
      />
    );
  }
  return (
    <NavigationSelect
      ariaLabel={label("branchBase")}
      fallbackValue={payload.branchBaseRef ?? ""}
      id="base-select"
      options={payload.baseOptions}
      onNavigate={onNavigate}
    />
  );
}

// Reads the FROZEN CONTRACT `branchPicker` object. In dev, a `?cmuxBranchPickerMock=1`
// query flag injects a local sample so the popover can be exercised without a
// wired backend. Production behavior is unchanged when the flag is absent.
function resolveBranchPicker(payload: any): BranchPickerPayload | null {
  const value = payload?.branchPicker;
  // Opt into the new picker only when the full FROZEN CONTRACT shape is present:
  // refsURL and regenerateURLTemplate must be non-empty strings (selection does
  // `regenerateURLTemplate.replace(...)`, which throws if it is missing), and
  // currentRef/headRef must be strings (rendered in the button label). Anything
  // missing falls back to the legacy <select>.
  if (isValidBranchPickerPayload(value)) {
    return value;
  }
  if (import.meta.env?.DEV && devBranchPickerMockEnabled()) {
    return devBranchPickerMock();
  }
  return null;
}

function isValidBranchPickerPayload(value: any): value is BranchPickerPayload {
  return Boolean(
    value &&
    typeof value === "object" &&
    typeof value.refsURL === "string" && value.refsURL !== "" &&
    typeof value.regenerateURLTemplate === "string" && value.regenerateURLTemplate !== "" &&
    typeof value.currentRef === "string" &&
    typeof value.headRef === "string",
  );
}

function devBranchPickerMockEnabled(): boolean {
  try {
    return new URLSearchParams(window.location.search).get("cmuxBranchPickerMock") === "1";
  } catch {
    return false;
  }
}

function devBranchPickerMock(): BranchPickerPayload {
  return {
    repoRoot: "/tmp/mock-repo",
    headRef: "feat-x",
    currentRef: "main",
    currentReason: "fork point",
    confidence: "low",
    aheadBehind: { ahead: 12, behind: 3 },
    refsURL: "data:application/json," + encodeURIComponent(JSON.stringify({
      groups: [
        { id: "suggested", label: "Suggested", rows: [
          { ref: "main", label: "main", reason: "fork point", confidence: "low", current: true },
          { ref: "origin/main", label: "origin/main", reason: "PR base" },
        ] },
        { id: "worktrees", label: "Worktrees", rows: [
          { ref: "feat-x", label: "feat-x", worktreeDir: "../worktrees/feat-x" },
        ] },
        { id: "branches", label: "Branches", rows: [
          { ref: "develop", label: "develop", secondary: "2 days ago" },
          { ref: "release/1.0", label: "release/1.0", secondary: "1 week ago" },
        ] },
        // Large remotes group so the render cap (top N + "... more") is
        // exercisable in DEV without a wired backend.
        { id: "remotes", label: "Remotes", rows: Array.from({ length: 2304 }, (_value, index) => ({
          ref: `origin/feature-${index}`,
          label: `origin/feature-${index}`,
        })) },
      ],
    })),
    regenerateURLTemplate: "about:blank#base={ref}",
  };
}

function NavigationSelect({
  ariaLabel,
  fallbackValue,
  id,
  onNavigate,
  onSelectSessionSource,
  options,
  selectedOptionTitle = false,
  selectedValue,
}: {
  ariaLabel: string;
  fallbackValue: string;
  id: string;
  onNavigate: (url: string) => void;
  onSelectSessionSource?: (source: DiffSource) => void;
  options: any[] | undefined;
  selectedOptionTitle?: boolean;
  selectedValue?: string | null;
}) {
  if (!Array.isArray(options) || options.length < 2) {
    return null;
  }
  const selected = options.find((option) => option.value === selectedValue)
    ?? options.find((option) => option.selected)
    ?? options.find((option) => !option.disabled);
  const selectedTitle = selectedOptionTitle
    ? (
        typeof selected?.message === "string" && selected.message.trim() !== ""
          ? selected.message
          : (String(selected?.value ?? fallbackValue).trim() || ariaLabel)
      )
    : ariaLabel;
  return (
    <select
      id={id}
      aria-label={ariaLabel}
      value={selected?.value ?? fallbackValue}
      title={selectedTitle}
      onChange={(event) => {
        const next = options.find((option) => option.value === event.currentTarget.value);
        if (validDiffSource(next?.sessionSource) && onSelectSessionSource) {
          onSelectSessionSource(next.sessionSource);
          return;
        }
        if (!next?.url) {
          event.currentTarget.value = selected?.value ?? fallbackValue;
          return;
        }
        onNavigate(next.url);
      }}
    >
      {options.map((option) => (
        <option
          key={option.value}
          value={option.value}
          disabled={option.disabled || (!option.url && !validDiffSource(option.sessionSource))}
          title={option.message}
        >
          {option.label}
        </option>
      ))}
    </select>
  );
}

function OptionsMenu({
  dispatch,
  externalURL,
  label,
  onCopyGitApply,
  onReload,
  onSetLayout,
  state,
}: {
  dispatch: React.Dispatch<AppAction>;
  externalURL: string | null;
  label: DiffViewerLabelResolver;
  onCopyGitApply: () => void;
  onReload: () => void;
  onSetLayout: (layout: DiffViewerLayout) => void;
  state: AppState;
}) {
  return (
    <div id="options-menu" aria-label={label("options")}>
      <MenuButton icon="refresh" label={label("refresh")} onClick={onReload} />
      <div className="menu-separator" />
      {/* The view options are shared with the repository header's menu (see
          ViewOptionsMenu.tsx). Secondary actions that can overflow from the bar
          at narrow widths are part of that list, so they stay reachable
          regardless of what the bar decided to drop: the bar hides its
          duplicate icon button when it overflows; the menu copy is canonical. */}
      <ViewOptionsMenuItems
        dispatch={dispatch}
        externalURL={externalURL}
        filesVisible={state.filesVisible}
        label={label}
        onSetLayout={onSetLayout}
        options={state.options}
      />
      <div className="menu-separator" />
      <MenuButton icon="clipboard" label={label("copyGitApplyCommand")} onClick={onCopyGitApply} />
    </div>
  );
}

function FilesSidebar({
  commentEntries,
  commentLabels,
  dispatch,
  hasDraft,
  label,
  onSelectComment,
  onSelectItem,
  selectable,
  selectedPath,
  state,
}: {
  commentEntries: SidebarCommentEntry[];
  commentLabels: DiffCommentLabels;
  dispatch: React.Dispatch<AppAction>;
  hasDraft: boolean;
  label: DiffViewerLabelResolver;
  onSelectComment: (entry: SidebarCommentEntry) => void;
  onSelectItem: (itemId: string) => void;
  /** Working-tree views with write actions: rows get checkboxes and the header a select-all. */
  selectable: boolean;
  selectedPath: string;
  state: AppState;
}) {
  const dragStart = useRef<{ startWidth: number; startX: number } | null>(null);
  // The tree model, for the search's matching paths (select all respects
  // the file search filter) and the shift-click range order. While the
  // search is open the header follows the tree's changes so the select-all
  // state tracks the filtered set.
  const [treeModel, setTreeModel] = useState<FileTreeModel | null>(null);
  const [, setTreeVersion] = useState(0);
  useEffect(() => {
    if (!treeModel || !state.fileSearchOpen) {
      return;
    }
    return treeModel.subscribe(() => setTreeVersion((version) => version + 1));
  }, [state.fileSearchOpen, treeModel]);
  const searchMatches = state.fileSearchOpen && treeModel?.isSearchOpen() ? treeModel.getSearchMatchingPaths() : null;
  const visiblePaths = selectable && state.treeSource ? visibleFilePaths(state.treeSource.paths, searchMatches) : [];
  const allState = selectAllState(state.selectedPaths, visiblePaths);
  const toggleSelection = (path: string, range: boolean) => {
    if (range && state.selectionAnchor != null) {
      dispatch({ type: "select-paths", paths: pathsInRange(visiblePaths, state.selectionAnchor, path), selected: true, anchor: path });
      return;
    }
    dispatch({ type: "toggle-selected-path", path });
  };
  const resizeFiles = (clientX: number) => {
    const start = dragStart.current;
    if (!start) {
      return;
    }
    const viewportWidth = document.documentElement.clientWidth || window.innerWidth;
    const maximumWidth = Math.max(220, Math.min(520, Math.floor(viewportWidth * 0.55)));
    const nextWidth = Math.max(180, Math.min(maximumWidth, Math.round(start.startWidth - (clientX - start.startX))));
    dispatch({ type: "set-files-width", width: nextWidth });
  };
  return (
    <aside id="files-sidebar" aria-label={label("changedFiles")} aria-hidden={!state.filesVisible} inert={!state.filesVisible}>
      <button
        id="files-resize-handle"
        aria-label={label("files")}
        type="button"
        tabIndex={0}
        onPointerDown={(event) => {
          dragStart.current = { startWidth: state.filesWidth, startX: event.clientX };
          event.currentTarget.setPointerCapture(event.pointerId);
        }}
        onPointerMove={(event) => resizeFiles(event.clientX)}
        onPointerUp={(event) => {
          resizeFiles(event.clientX);
          dragStart.current = null;
          event.currentTarget.releasePointerCapture(event.pointerId);
        }}
        onPointerCancel={() => {
          dragStart.current = null;
        }}
        onKeyDown={(event) => {
          if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") {
            return;
          }
          event.preventDefault();
          const delta = event.key === "ArrowLeft" ? 20 : -20;
          dispatch({ type: "set-files-width", width: Math.max(180, Math.min(520, state.filesWidth + delta)) });
        }}
      />
      <div id="files-header">
        <span id="files-title">
          {selectable ? (
            <input
              id="files-select-all"
              type="checkbox"
              className="file-select-checkbox"
              aria-label={label("selectAllFiles")}
              title={label("selectAllFiles")}
              checked={allState === "all"}
              disabled={visiblePaths.length === 0}
              ref={(node) => {
                if (node) {
                  node.indeterminate = allState === "some";
                }
              }}
              onChange={() => dispatch({ type: "select-paths", paths: visiblePaths, selected: selectAllToggleSelects(allState) })}
            />
          ) : null}
          <span>{label("files")}</span>
          <span id="files-count">{state.treeSource?.pathCount ?? 0}</span>
        </span>
        <span id="files-header-actions">
          <button
            id="file-search-toggle"
            type="button"
            title={state.fileSearchOpen ? label("hideFileSearch") : label("showFileSearch")}
            aria-label={state.fileSearchOpen ? label("hideFileSearch") : label("showFileSearch")}
            aria-pressed={state.fileSearchOpen}
            disabled={!state.treeSource}
            onClick={() => state.fileSearchOpen
              ? closeFileSearch(dispatch)
              : dispatch({ type: "set-file-search-open", open: true })}
          >
            <Icon name="search" />
          </button>
        </span>
      </div>
      <div id="file-list">
        {state.treeSource ? (
          <PierreFileTree
            fileSearchOpen={state.fileSearchOpen}
            fileSearchRequest={state.fileSearchRequest}
            label={label}
            onModel={setTreeModel}
            onSelectItem={onSelectItem}
            onToggleSelection={toggleSelection}
            selectable={selectable}
            selectedPath={selectedPath}
            selectedPaths={state.selectedPaths}
            source={state.treeSource}
          />
        ) : state.status.loading || state.status.pending ? (
          <LoadingFileList />
        ) : (
          <div className="visually-hidden">{state.status.message}</div>
        )}
      </div>
      <CommentsSidebarSection
        entries={commentEntries}
        hasDraft={hasDraft}
        labels={commentLabels}
        onSelect={onSelectComment}
      />
    </aside>
  );
}

function PierreFileTree({
  fileSearchOpen,
  fileSearchRequest,
  label,
  onModel,
  onSelectItem,
  onToggleSelection,
  selectable,
  selectedPath,
  selectedPaths,
  source,
}: {
  fileSearchOpen: boolean;
  fileSearchRequest: number;
  label: DiffViewerLabelResolver;
  onModel: (model: FileTreeModel) => void;
  onSelectItem: (itemId: string) => void;
  /** A row checkbox was clicked (shift held: `range`) or toggled with Space. */
  onToggleSelection: (path: string, range: boolean) => void;
  selectable: boolean;
  selectedPath: string;
  selectedPaths: FileSelection;
  source: FileTreeSource;
}) {
  const latest = useSyncedRef({ label, onSelectItem, onToggleSelection, selectable, selectedPaths, source });
  const [initialPreparedInput] = useState(() => preparePresortedFileTreeInput(source.paths));
  const { model } = useFileTree({
    flattenEmptyDirectories: false,
    id: "cmux-diff-file-tree",
    initialExpansion: "open",
    initialSelectedPaths: selectedPath ? [selectedPath] : [],
    initialVisibleRowCount: getInitialFileTreeRowCount(),
    itemHeight: 24,
    overscan: 12,
    preparedInput: initialPreparedInput,
    search: true,
    searchBlurBehavior: "retain",
    stickyFolders: true,
    gitStatus: source.gitStatus as any,
    sort: () => 0,
    unsafeCSS: fileTreeUnsafeCSS(),
    // The row checkbox: the tree's custom decoration lane, drawn from the
    // selection sprite. Read through the ref so a re-render after a
    // selection change (below) sees the current set.
    icons: { set: "complete", spriteSheet: FILE_TREE_SELECTION_SPRITE },
    renderRowDecoration({ row }) {
      const current = latest.current;
      if (!current.selectable || row.kind !== "file" || !current.source.pathToItemId.has(row.path)) {
        return null;
      }
      return selectionDecoration(
        current.selectedPaths.has(row.path),
        formatLabel(current.label("selectFile"), { name: row.name }),
      );
    },
    onSelectionChange(paths: readonly string[]) {
      const path = paths[paths.length - 1];
      const itemId = latest.current.source.pathToItemId.get(path);
      if (itemId) {
        latest.current.onSelectItem(itemId);
      }
    },
  });

  usePierreFileTreeSource(model, source);
  usePierreFileTreeSearch(model, fileSearchOpen, fileSearchRequest);
  usePierreFileTreeSelection(model, selectedPath);
  useEffect(() => {
    onModel(model);
  }, [model, onModel]);
  // The tree renders its rows itself and reads the decoration renderer at
  // render time, so a selection change asks it to render again; reapplying
  // its own composition is the public way to do that. Runs after the
  // synced ref above has the new set.
  useEffect(() => {
    model.setComposition(model.getComposition());
  }, [model, selectable, selectedPaths]);

  // Clicks and Space on a row's checkbox lane are taken here, in the
  // capture phase above the tree's shadow root, so the tree never sees
  // them: checking a file must not navigate to it. Everything else
  // (the row name, folders, the search box) reaches the tree untouched.
  const captureCheckboxClick = (event: React.MouseEvent) => {
    if (!latest.current.selectable) {
      return;
    }
    const path = selectionRowPathFromComposedPath(event.nativeEvent.composedPath());
    if (path == null) {
      return;
    }
    event.preventDefault();
    event.stopPropagation();
    event.nativeEvent.stopPropagation();
    latest.current.onToggleSelection(path, event.shiftKey);
  };
  const captureCheckboxKey = (event: React.KeyboardEvent) => {
    if (!latest.current.selectable || !isPlainSpace(event)) {
      return;
    }
    const path = focusedFileRowPath(event.nativeEvent.composedPath()[0] ?? null);
    if (path == null) {
      return;
    }
    event.preventDefault();
    event.stopPropagation();
    event.nativeEvent.stopPropagation();
    latest.current.onToggleSelection(path, false);
  };

  return (
    // oxlint-disable-next-line jsx-a11y/no-static-element-interactions
    <div
      className="file-tree-host"
      onClickCapture={captureCheckboxClick}
      onKeyDownCapture={captureCheckboxKey}
    >
      <FileTree model={model} style={{ height: "100%" }} />
    </div>
  );
}

function LoadingFileList() {
  return (
    <div className="diff-loading-placeholder" aria-hidden="true">
      {fileSkeletonWidths.map((width, index) => (
        <div key={`${width}-${index}`} className="grid h-6 grid-cols-[16px_minmax(0,1fr)_44px] items-center gap-2 rounded-[5px] px-[7px]">
          <span className="size-4 rounded-[5px] border border-[color-mix(in_lab,var(--cmux-diff-fg)_18%,transparent)]" />
          <span className="h-[11px] rounded bg-[var(--cmux-diff-muted-bg)]" style={{ width }} />
          <span className="h-[11px] justify-self-end rounded bg-[var(--cmux-diff-muted-bg)] opacity-70" style={{ width: index % 2 === 0 ? "34px" : "24px" }} />
        </div>
      ))}
    </div>
  );
}

function LoadingDiffSkeleton() {
  return (
    <div className="diff-loading-placeholder mx-3.5 mt-3.5 border-t border-[var(--cmux-diff-border)] pt-3" aria-hidden="true">
      <div className="mb-3 grid h-9 grid-cols-[72px_minmax(0,1fr)_96px] items-center gap-3 rounded-md bg-[color-mix(in_lab,var(--cmux-diff-fg)_5%,transparent)] px-3">
        <span className="h-3 rounded bg-[var(--cmux-diff-muted-bg)]" />
        <span className="h-3 w-2/5 rounded bg-[var(--cmux-diff-muted-bg)]" />
        <span className="h-3 rounded bg-[var(--cmux-diff-muted-bg)] opacity-70" />
      </div>
      <div className="space-y-[13px] px-3 py-1">
        {diffSkeletonWidths.map((width, index) => (
          <div key={`${width}-${index}`} className="grid grid-cols-[42px_minmax(0,1fr)] items-center gap-4">
            <span className="h-px bg-[color-mix(in_lab,var(--cmux-diff-fg)_10%,transparent)]" />
            <span className="h-3 rounded bg-[var(--cmux-diff-muted-bg)]" style={{ width }} />
          </div>
        ))}
      </div>
    </div>
  );
}

function LoadingLayer({ label, status }: { label: DiffViewerLabelResolver; status: DiffViewerStatus }) {
  if (!status.loading && !status.pending && !status.statusOnly && !status.error) {
    return null;
  }
  return (
    <div id="loading-layer" aria-live="polite">
      <div id="status" data-error={status.error ? "true" : "false"} data-pending={status.pending ? "true" : "false"}>
        <span id="status-icon" aria-hidden="true" />
        <span id="status-text">{status.message || label("loadingDiff")}</span>
      </div>
      {status.loading || status.pending ? <LoadingDiffSkeleton /> : null}
    </div>
  );
}

function useSyncedRef<T>(value: T): React.MutableRefObject<T> {
  const ref = useRef(value);
  useEffect(() => {
    ref.current = value;
  }, [value]);
  return ref;
}

function useWorkerRenderOptionsSync(
  highlighterOptions: ReturnType<typeof workerHighlighterOptions>,
  codeViewRef: React.MutableRefObject<CodeViewHandle<any> | null>,
): void {
  const workerPool = useWorkerPool();
  const syncedOptions = useRef<ReturnType<typeof workerHighlighterOptions> | null>(null);
  useEffect(() => {
    if (!workerPool || sameWorkerHighlighterOptions(syncedOptions.current, highlighterOptions)) {
      return;
    }
    let active = true;
    syncedOptions.current = highlighterOptions;
    workerPool.setRenderOptions(highlighterOptions)
      .then(() => {
        if (active) {
          codeViewRef.current?.getInstance()?.render(true);
        }
      })
      .catch((error: unknown) => console.warn("cmux diff worker render options update failed", error));
    return () => {
      active = false;
    };
  }, [codeViewRef, highlighterOptions, workerPool]);
}

function sameWorkerHighlighterOptions(
  previous: ReturnType<typeof workerHighlighterOptions> | null,
  next: ReturnType<typeof workerHighlighterOptions>,
): boolean {
  return previous?.lineDiffType === next.lineDiffType &&
    sameStringArray(previous?.langs, next.langs) &&
    previous?.maxLineDiffLength === next.maxLineDiffLength &&
    previous?.preferredHighlighter === next.preferredHighlighter &&
    sameThemeOption(previous?.theme, next.theme) &&
    previous?.tokenizeMaxLineLength === next.tokenizeMaxLineLength &&
    previous?.useTokenTransformer === next.useTokenTransformer;
}

function sameStringArray(previous: readonly string[] | undefined, next: readonly string[] | undefined): boolean {
  if (previous === next) {
    return true;
  }
  if (previous == null || next == null || previous.length !== next.length) {
    return false;
  }
  return previous.every((value, index) => value === next[index]);
}

function sameThemeOption(
  previous: ReturnType<typeof workerHighlighterOptions>["theme"] | undefined,
  next: ReturnType<typeof workerHighlighterOptions>["theme"],
): boolean {
  if (previous === next) {
    return true;
  }
  if (typeof previous !== "object" || previous == null || typeof next !== "object" || next == null) {
    return false;
  }
  return (previous as { dark?: string }).dark === (next as { dark?: string }).dark &&
    (previous as { light?: string }).light === (next as { light?: string }).light;
}

function usePierreFileTreeSource(
  model: ReturnType<typeof useFileTree>["model"],
  source: FileTreeSource,
): void {
  const previousSource = useRef<FileTreeSource | null>(null);
  useEffect(() => {
    const previous = previousSource.current;
    previousSource.current = source;
    const plan = planPierreFileTreeRefresh(previous, source, source.paths);
    let useFullGitStatus = plan.kind === "append" ? plan.requiresFullGitStatus : false;
    if (plan.kind === "append") {
      if (plan.addedPaths.length > 0) {
        try {
          model.batch(plan.addedPaths.map((path) => ({ type: "add", path })));
          useFullGitStatus = !plan.sourceFollowsPrevious;
        } catch {
          const preparedInput = preparePresortedFileTreeInput(source.paths);
          model.resetPaths(source.paths, { preparedInput });
          useFullGitStatus = true;
        }
      }
    } else {
      const preparedInput = preparePresortedFileTreeInput(source.paths);
      model.resetPaths(source.paths, { preparedInput });
      useFullGitStatus = true;
    }
    applyPierreFileTreeGitStatus(model as any, source, useFullGitStatus);
  }, [model, source]);
}

function usePierreFileTreeSearch(
  model: ReturnType<typeof useFileTree>["model"],
  fileSearchOpen: boolean,
  fileSearchRequest: number,
): void {
  useEffect(() => {
    if (fileSearchOpen) {
      const wasOpen = model.isSearchOpen();
      model.openSearch(wasOpen ? model.getSearchValue() : "");
      if (wasOpen) {
        const container = model.getFileTreeContainer();
        const root = container?.shadowRoot ?? container?.getRootNode();
        (root as ParentNode | undefined)?.querySelector<HTMLInputElement>("[data-file-tree-search-input]")?.focus();
      }
    } else {
      model.closeSearch();
    }
  }, [fileSearchOpen, fileSearchRequest, model]);
}

function usePierreFileTreeSelection(model: ReturnType<typeof useFileTree>["model"], selectedPath: string): void {
  useEffect(() => {
    selectPierreFileTreePath(model, selectedPath);
  }, [model, selectedPath]);
}

function useRenderDiff(
  config: DiffViewerConfig,
  transport: DiffTransport | null,
  label: DiffViewerLabelResolver,
  dispatch: React.Dispatch<AppAction>,
  latestState: React.MutableRefObject<AppState>,
  onPatchURL: (url: string) => void,
  activeSessionRef: React.MutableRefObject<ActiveDiffSession | null>,
  closeActiveSession: () => Promise<void>,
  sessionSource: DiffSource | null,
  onResolvedSessionSource: (source: DiffSource) => void,
  restoreScrollRef: React.MutableRefObject<number | null>,
  onSessionSettled: () => void,
) {
  useEffect(() => {
    if (isStatusOnlyPayload(config.payload, transport, sessionSource)) {
      return;
    }
    const payload = config.payload ?? {};
    const appearance = resolveDiffViewerAppearance(payload.appearance);
    for (const theme of [appearance.themes.light, appearance.themes.dark]) {
      if (theme.name && !registeredCustomThemeNames.has(theme.name)) {
        registerCustomTheme(theme.name, () => Promise.resolve(shikiThemeFromGhostty(theme, appearance)));
        registeredCustomThemeNames.add(theme.name);
      }
    }
    let cancelled = false;
    const streamAbortController = new AbortController();
    const handlePageHide = () => {
      void closeActiveSession();
    };
    window.addEventListener("pagehide", handlePageHide);
    void (async () => {
      try {
        let patchURL = payload.patchURL as string | undefined;
        const session = diffSessionRequest(payload, transport, sessionSource);
        if (session) {
          const result = await transport!.request({ method: "sessionOpen", params: session });
          if (result.type !== "sessionOpened") {
            throw new DiffTransportError("invalidResponse", "Diff transport did not open a session");
          }
          const openedSession = {
            sessionId: result.value.sessionId,
            capabilityToken: String(payload.capabilityToken ?? ""),
          };
          if (cancelled) {
            await closeDiffSession(transport!, openedSession);
            return;
          }
          activeSessionRef.current = openedSession;
          onResolvedSessionSource(result.value.source);
          patchURL = result.value.patch.id;
        }
        if (cancelled) {
          return;
        }
        // The (re)opened session exists, or this page has none to wait for:
        // a write action held for the reload may run again.
        onSessionSettled();
        if (!patchURL) {
          return;
        }
        onPatchURL(patchURL);
        const streamedItems: DiffItem[] = [];
        dispatch({ type: "set-status", status: createDiffViewerStatus(label("parsingDiff"), { loading: true }) });
        await streamPatch({
          getCollapsed: () => latestState.current.options.collapsed,
          initialFileTreeRowCount: getInitialFileTreeRowCount(),
          label,
          signal: streamAbortController.signal,
          onBatch: (items) => {
            if (cancelled) return;
            streamedItems.push(...items);
            dispatch({ type: "append-items", items });
          },
          onComplete: (metrics) => {
            if (cancelled) return;
            dispatch({ type: "set-metrics", metrics });
            const items = streamedItems;
            if (items.length === 0) {
              // Nothing to scroll back to; a pending restore must not fire
              // on the next stream instead.
              restoreScrollRef.current = null;
              const emptyMessage = typeof payload.emptyMessage === "string" ? payload.emptyMessage : label("noFileDiffs");
              dispatch({ type: "set-status", status: createDiffViewerStatus(emptyMessage, { error: false, loading: false, statusOnly: true }) });
              return;
            }
            const themes = Array.from(new Set([appearance.theme?.light, appearance.theme?.dark].filter(Boolean)));
            const langs = Array.from(new Set(items.flatMap((item) => {
              const diff = item.fileDiff ?? {};
              return resolveDiffPreloadLanguages(fileName(diff, ""), diff.lang, diff, getFiletypeFromFileName);
            })));
            preloadHighlighter({ themes, langs: langs.length > 0 ? langs : ["text"] })
              .catch((error) => console.warn("cmux diff highlighter preload failed", error));
          },
          onMetrics: (metrics) => {
            if (!cancelled) dispatch({ type: "set-metrics", metrics });
          },
          onRename: (rename) => {
            if (!cancelled) dispatch({ type: "rename-item", oldId: rename.oldId, newId: rename.newId });
          },
          onTreeSource: (source) => {
            if (!cancelled) dispatch({ type: "set-tree-source", source });
          },
          parsePatchFiles,
          patchURL,
          processFile,
        });
      } catch (error) {
        if (cancelled) {
          return;
        }
        restoreScrollRef.current = null;
        onSessionSettled();
        const empty = error instanceof DiffTransportError && error.code === "emptyDiff";
        if (!empty) {
          // Error objects JSON.stringify to {} in the native console mirror,
          // so serialize the message and stack explicitly.
          console.error(
            "cmux diff viewer render failed",
            String((error as any)?.stack ?? (error as any)?.message ?? error),
          );
        }
        const emptyMessage = typeof payload.emptyMessage === "string" ? payload.emptyMessage : label("noFileDiffs");
        dispatch({
          type: "set-status",
          status: createDiffViewerStatus(empty ? emptyMessage : label("renderFailed"), {
            error: !empty,
            loading: false,
            statusOnly: true,
          }),
        });
      }
    })();
    return () => {
      cancelled = true;
      streamAbortController.abort();
      window.removeEventListener("pagehide", handlePageHide);
      void closeActiveSession();
    };
  }, [activeSessionRef, closeActiveSession, config, dispatch, label, latestState, onPatchURL, onResolvedSessionSource, onSessionSettled, restoreScrollRef, sessionSource, transport]);
}

function closeDiffSession(transport: DiffTransport, session: ActiveDiffSession): Promise<void> {
  return transport.request({ method: "sessionClose", params: session }).then(() => {}, () => {});
}

function diffSessionRequest(payload: any, transport: DiffTransport | null, overrideSource?: DiffSource | null): {
  source: DiffSource;
  capabilityToken: string;
} | null {
  if (!transport || typeof payload?.capabilityToken !== "string") {
    return null;
  }
  const source = overrideSource ?? payload.sessionSource;
  if (!validDiffSource(source)) {
    return null;
  }
  return { source, capabilityToken: payload.capabilityToken };
}

function validDiffSource(value: unknown): value is DiffSource {
  if (!value || typeof value !== "object" || typeof (value as { kind?: unknown }).kind !== "string") {
    return false;
  }
  const source = value as { kind: string; repoRoot?: unknown; path?: unknown; baseRef?: unknown };
  if (source.kind === "patch") {
    return typeof source.path === "string";
  }
  if (source.kind === "unstaged" || source.kind === "staged") {
    return typeof source.repoRoot === "string";
  }
  return source.kind === "branch"
    && typeof source.repoRoot === "string"
    && (source.baseRef == null || typeof source.baseRef === "string");
}

function diffSourceKind(source: DiffSource | null): string | null {
  return source?.kind ?? null;
}

function diffSourceRepoRoot(source: DiffSource | null): string | null {
  return source && "repoRoot" in source ? source.repoRoot : null;
}

function sourceSelectionWithActiveRepo(source: DiffSource, active: DiffSource | null): DiffSource {
  if (source.kind === "patch") {
    return source;
  }
  const activeRepo = diffSourceRepoRoot(active);
  if (!activeRepo) {
    return source;
  }
  if (source.kind === "branch") {
    return source.repoRoot === activeRepo
      ? { ...source, repoRoot: activeRepo }
      : { kind: "branch", repoRoot: activeRepo };
  }
  return { ...source, repoRoot: activeRepo };
}

function repoSelectionWithActiveSource(source: DiffSource, active: DiffSource | null): DiffSource {
  const repoRoot = diffSourceRepoRoot(source);
  if (!repoRoot || !active || active.kind === "patch") {
    return source;
  }
  if (active.kind === "branch") {
    return active.repoRoot === repoRoot
      ? { ...active, repoRoot }
      : { kind: "branch", repoRoot };
  }
  return { ...active, repoRoot };
}

function resolveDiffItemLanguage(item: DiffItem): void {
  const diff = item.fileDiff;
  if (diff == null) {
    return;
  }
  const lang = resolveDiffFileLanguage(fileName(diff, ""), diff.lang, getFiletypeFromFileName);
  diff.lang = lang;
}

function diffItemPreloadLanguages(item: DiffItem): string[] {
  const diff = item.fileDiff;
  if (diff == null) {
    return [];
  }
  return resolveDiffPreloadLanguages(fileName(diff, ""), diff.lang, diff, getFiletypeFromFileName);
}

function mergeLanguages(current: string[], next: string[]): string[] {
  const languages = new Set(current);
  for (const language of next) {
    if (language.trim().length > 0) {
      languages.add(language);
    }
  }
  return Array.from(languages);
}

function isStatusOnlyPayload(
  payload: any,
  transport: DiffTransport | null = null,
  sessionSource: DiffSource | null = null,
): boolean {
  if (payload?.pendingReplacement === true) {
    return diffSessionRequest(payload, transport, sessionSource) == null;
  }
  return typeof payload?.statusMessage === "string" && payload.statusMessage.length > 0;
}

function usePendingReplacement(
  payload: any,
  label: DiffViewerLabelResolver,
  dispatch: React.Dispatch<AppAction>,
  transport: DiffTransport | null,
) {
  const started = useRef(false);
  useEffect(() => {
    if (started.current) {
      return;
    }
    started.current = true;
    if (payload.pendingReplacement === true) {
      dispatch({
        type: "set-status",
        status: createDiffViewerStatus(payload.statusMessage ?? label("loadingDiff"), { loading: true, pending: true }),
      });
      if (diffSessionRequest(payload, transport)) {
        return;
      }
      // The native host replaces the file and navigates this surface when Git
      // generation completes. Custom-scheme resources never use an HTTP wait
      // endpoint, so keep the loading state until that navigation arrives.
      if (window.location.protocol === "cmux-diff-viewer:") {
        return;
      }
      fetch("/__cmux_diff_viewer_wait" + window.location.pathname, { cache: "no-store" })
        .then(async (response) => {
          if (!response.ok) {
            throw new Error("replacement failed");
          }
          const text = await response.text();
          if (!text.includes("data-cmux-diff-pending=\"true\"")) {
            window.location.reload();
          }
        })
        .catch((error) => {
          document.documentElement.dataset.cmuxDiffWait = "failed";
          dispatch({ type: "set-status", status: createDiffViewerStatus(label("renderFailed"), { error: true, loading: false, statusOnly: true }) });
          console.warn("cmux diff viewer deferred load failed", error);
        });
      return;
    }
    if (typeof payload.statusMessage === "string" && payload.statusMessage.length > 0) {
      dispatch({
        type: "set-status",
        status: createDiffViewerStatus(payload.statusMessage, {
          error: payload.statusIsError === true,
          loading: false,
          statusOnly: true,
        }),
      });
    }
  }, [dispatch, label, payload, transport]);
}

function usePageDataAttributes(state: AppState) {
  useEffect(() => {
    document.body.dataset.filesHidden = state.filesVisible ? "false" : "true";
    document.body.dataset.loading = state.status.loading ? "true" : "false";
    document.documentElement.dataset.layout = state.options.layout;
    document.documentElement.dataset.wordWrap = String(state.options.wordWrap);
    document.documentElement.dataset.diffIndicators = state.options.diffIndicators;
    if (state.metrics) {
      document.body.dataset.streamFileCount = String(state.metrics.fileCount ?? state.items.length);
      document.body.dataset.streamRenderableFileCount = String(state.metrics.renderableFileCount ?? state.items.length);
      document.body.dataset.streamFlushCount = String(state.metrics.flushCount ?? 0);
      document.body.dataset.streamMaxBatchSize = String(state.metrics.maxBatchSize ?? 0);
      document.body.dataset.streamTreeRefreshCount = String(state.metrics.treeRefreshCount ?? 0);
      if (Number.isFinite(state.metrics.completedAt) && state.metrics.completedAt > 0) {
        document.body.dataset.streamElapsedMs = String(Math.round(state.metrics.completedAt - state.metrics.startedAt));
      }
    }
    applyDiffViewerStatusToDocument(state.status);
  }, [state]);
}

function useNativeViewerNavigation(
  viewerRef: React.MutableRefObject<HTMLDivElement | null>,
  dispatch: React.Dispatch<AppAction>,
  onJumpAdjacentFile: (direction: -1 | 1) => void,
  findBridgeRef: React.MutableRefObject<{ open: boolean; controller: DiffFindController }>,
) {
  useEffect(() => {
    window.__cmuxPerformDiffViewerNavigationAction = (action: string) => {
      const viewer = viewerRef.current;
      if (viewer && CmuxViewerNavigation.performAction(action, viewer)) {
        return true;
      }
      const findBridge = findBridgeRef.current;
      switch (action) {
        case "diffViewerOpenFileSearch":
          dispatch({ type: "request-file-search" });
          return true;
        case "diffViewerNextFile":
          if (viewer) CmuxViewerNavigation.resetSmoothTarget(viewer);
          onJumpAdjacentFile(1);
          return true;
        case "diffViewerPreviousFile":
          if (viewer) CmuxViewerNavigation.resetSmoothTarget(viewer);
          onJumpAdjacentFile(-1);
          return true;
        case "diffViewerOpenFind":
          dispatch({ type: "request-find" });
          return true;
        case "diffViewerFindNext":
          if (!findBridge.open) return false;
          findBridge.controller.goToNext();
          return true;
        case "diffViewerFindPrevious":
          if (!findBridge.open) return false;
          findBridge.controller.goToPrevious();
          return true;
        case "diffViewerCloseFind":
          if (!findBridge.open) return false;
          findBridge.controller.closeFind();
          return true;
      }
      return false;
    };
    document.documentElement.dataset.cmuxViewerNavigationReady = "true";
    document.dispatchEvent(new window.Event("cmux-diff-viewer-navigation-readiness-change"));
    const disposeManualInputReset = CmuxViewerNavigation.installManualInputReset({
      target: document,
      getScroller: () => viewerRef.current!,
    });
    return () => {
      delete window.__cmuxPerformDiffViewerNavigationAction;
      delete document.documentElement.dataset.cmuxViewerNavigationReady;
      document.dispatchEvent(new window.Event("cmux-diff-viewer-navigation-readiness-change"));
      disposeManualInputReset();
    };
  }, [dispatch, findBridgeRef, onJumpAdjacentFile, viewerRef]);
}

/**
 * Installs `window.cmuxDiffViewer.refresh()` for the host. The object is
 * created once and routes through a ref, so it always runs the latest
 * closure (the current source, session, and pending state); it is removed on
 * unmount.
 */
function useHostRefresh(refreshRef: React.MutableRefObject<() => boolean>) {
  useEffect(() => {
    window.cmuxDiffViewer = { refresh: () => refreshRef.current() };
    return () => {
      delete window.cmuxDiffViewer;
    };
  }, [refreshRef]);
}

export function closeFileSearch(dispatch: React.Dispatch<AppAction>, targetDocument: Document = document) {
  dispatch({ type: "set-file-search-open", open: false });
  const trigger = targetDocument.getElementById("file-search-toggle");
  trigger?.focus();
}

export function shouldDismissFileSearch(key: string, narrowViewport: boolean): boolean {
  return key === "Escape" && narrowViewport;
}

function useFileSearchDismiss(fileSearchOpen: boolean, dispatch: React.Dispatch<AppAction>) {
  useEffect(() => {
    if (!fileSearchOpen) {
      return;
    }
    const closeOnEscape = (event: KeyboardEvent) => {
      if (shouldDismissFileSearch(event.key, window.matchMedia("(max-width: 520px)").matches)) {
        event.preventDefault();
        closeFileSearch(dispatch);
      }
    };
    document.addEventListener("keydown", closeOnEscape);
    return () => document.removeEventListener("keydown", closeOnEscape);
  }, [dispatch, fileSearchOpen]);
}

/**
 * One handshake per page: the sidecar's advertised capabilities gate the
 * write actions so a host without `worktree.write` renders a read-only diff.
 */
function useSidecarCapabilities(transport: DiffTransport | null, enabled: boolean): string[] | null {
  const [capabilities, setCapabilities] = useState<string[] | null>(null);
  useEffect(() => {
    if (!transport || !enabled) {
      return;
    }
    let cancelled = false;
    transport.request({ method: "protocolHandshake" })
      .then((result) => {
        if (!cancelled && result.type === "handshake") {
          setCapabilities(result.value.capabilities);
        }
      })
      .catch((error) => console.warn("cmux diff sidecar handshake failed", error));
    return () => {
      cancelled = true;
    };
  }, [enabled, transport]);
  return capabilities;
}

function useDiffTransport(config: DiffTransportConfig | undefined): DiffTransport | null {
  const transportRef = useRef<DiffTransport | null | undefined>(undefined);
  if (transportRef.current === undefined) {
    transportRef.current = createDiffTransport(config);
  }
  useEffect(() => {
    const transport = transportRef.current;
    return () => transport?.close();
  }, []);
  return transportRef.current;
}

function scrollTargetForItem(itemId: string, items: DiffItem[]): string {
  if (items.some((item) => item.id === itemId)) {
    return itemId;
  }
  return items[0]?.id ?? "";
}

export function adjacentItemId(activeItemId: string, items: DiffItem[], direction: -1 | 1): string {
  if (items.length === 0) {
    return "";
  }
  const currentIndex = items.findIndex((item) => item.id === activeItemId);
  if (currentIndex < 0) {
    return direction > 0 ? items[0].id : items[items.length - 1].id;
  }
  const targetIndex = currentIndex + direction;
  return targetIndex >= 0 && targetIndex < items.length ? items[targetIndex].id : "";
}

export function visibleItemId(
  items: DiffItem[],
  scrollTop: number,
  getTopForItem: (itemId: string) => number | undefined,
): string {
  let low = 0;
  let high = items.length - 1;
  let visibleIndex = items.length > 0 ? 0 : -1;
  while (low <= high) {
    const middle = Math.floor((low + high) / 2);
    const top = getTopForItem(items[middle].id);
    if (top != null && top <= scrollTop + 1) {
      visibleIndex = middle;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return visibleIndex >= 0 ? items[visibleIndex].id : "";
}

function getInitialFileTreeRowCount(): number {
  const viewportHeight = window.visualViewport?.height ?? window.innerHeight;
  if (!Number.isFinite(viewportHeight) || viewportHeight <= 0) {
    return 25;
  }
  return Math.min(96, Math.max(25, Math.ceil(viewportHeight / 24)));
}
