// The file selection of a working-tree view: which file paths are checked
// for a selection-scoped stage / unstage / discard. Pure set logic the App's
// reducer applies; the React layer only renders the resulting set. Paths are
// the file list's tree paths (the same keys the file tree and the cards
// share), scoped to one view: the reducer clears the set when the view,
// repository or base changes and prunes it to the paths still present once a
// reload after a write has streamed.

export type FileSelection = ReadonlySet<string>;

export const EMPTY_SELECTION: FileSelection = new Set<string>();

/** Adds `path` when absent, removes it when present. */
export function toggleSelectedPath(
  selection: FileSelection,
  path: string,
): FileSelection {
  const next = new Set(selection);
  if (!next.delete(path)) {
    next.add(path);
  }
  return next;
}

/**
 * Marks every path in `paths` selected or not. Returns `selection` itself
 * when nothing changes, so a reducer can skip the re-render.
 */
export function setPathsSelected(
  selection: FileSelection,
  paths: Iterable<string>,
  selected: boolean,
): FileSelection {
  let next: Set<string> | null = null;
  for (const path of paths) {
    if (selection.has(path) === selected) {
      continue;
    }
    next ??= new Set(selection);
    if (selected) {
      next.add(path);
    } else {
      next.delete(path);
    }
  }
  return next ?? selection;
}

/**
 * Drops every selected path `isPresent` no longer knows. Returns
 * `selection` itself when every path survives.
 */
export function pruneSelection(
  selection: FileSelection,
  isPresent: (path: string) => boolean,
): FileSelection {
  let next: Set<string> | null = null;
  for (const path of selection) {
    if (isPresent(path)) {
      continue;
    }
    next ??= new Set(selection);
    next.delete(path);
  }
  return next ?? selection;
}

/** The tri-state of a "select all" control over the `visible` paths. */
export type SelectAllState = "none" | "some" | "all";

export function selectAllState(
  selection: FileSelection,
  visible: readonly string[],
): SelectAllState {
  if (visible.length === 0) {
    return "none";
  }
  let selected = 0;
  for (const path of visible) {
    if (selection.has(path)) {
      selected += 1;
    }
  }
  if (selected === 0) {
    return "none";
  }
  return selected === visible.length ? "all" : "some";
}

/**
 * The inclusive run of `order` between `anchor` and `target`, in list order,
 * for a shift-click. Without a usable anchor (none yet, or one no longer in
 * the list) the range is the target alone.
 */
export function pathsInRange(
  order: readonly string[],
  anchor: string | null,
  target: string,
): string[] {
  const targetIndex = order.indexOf(target);
  if (targetIndex < 0) {
    return [target];
  }
  const anchorIndex = anchor == null ? -1 : order.indexOf(anchor);
  if (anchorIndex < 0) {
    return [target];
  }
  const start = Math.min(anchorIndex, targetIndex);
  const end = Math.max(anchorIndex, targetIndex);
  return order.slice(start, end + 1);
}

/**
 * The file paths a "select all" acts on: every file of the list (the list
 * itself), narrowed to the search's matches while a file search is open
 * (`searchMatches` is `null` when it is not). Directory paths the search
 * reports are dropped.
 */
export function visibleFilePaths(
  filePaths: readonly string[],
  searchMatches: readonly string[] | null,
): readonly string[] {
  if (searchMatches == null) {
    return filePaths;
  }
  const files = new Set(filePaths);
  return searchMatches.filter((path) => files.has(path));
}
