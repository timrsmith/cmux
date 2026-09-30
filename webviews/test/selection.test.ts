import { describe, expect, test } from "bun:test";
import {
  EMPTY_SELECTION,
  pathsInRange,
  pruneSelection,
  selectAllState,
  selectAllToggleSelects,
  setPathsSelected,
  toggleSelectedPath,
  visibleFilePaths,
} from "../src/selection";

describe("file selection model", () => {
  test("toggling adds an absent path and removes a present one without mutating the input", () => {
    const one = toggleSelectedPath(EMPTY_SELECTION, "a.ts");
    expect([...one]).toEqual(["a.ts"]);
    expect(EMPTY_SELECTION.size).toBe(0);
    const two = toggleSelectedPath(one, "b.ts");
    expect([...two]).toEqual(["a.ts", "b.ts"]);
    expect([...toggleSelectedPath(two, "a.ts")]).toEqual(["b.ts"]);
    expect([...two]).toEqual(["a.ts", "b.ts"]);
  });

  test("setting paths selected or not returns the same set when nothing changes", () => {
    const selection = new Set(["a.ts", "b.ts"]);
    expect(setPathsSelected(selection, ["a.ts", "b.ts"], true)).toBe(selection);
    expect(setPathsSelected(selection, ["c.ts"], false)).toBe(selection);
    expect(setPathsSelected(selection, [], true)).toBe(selection);
    expect([...setPathsSelected(selection, ["c.ts", "a.ts"], true)]).toEqual([
      "a.ts",
      "b.ts",
      "c.ts",
    ]);
    expect([...setPathsSelected(selection, ["a.ts", "zzz"], false)]).toEqual(["b.ts"]);
    expect([...selection]).toEqual(["a.ts", "b.ts"]);
  });

  test("pruning keeps only the paths still present, and the same set when all survive", () => {
    const selection = new Set(["a.ts", "gone.ts", "b.ts"]);
    const present = new Set(["a.ts", "b.ts", "other.ts"]);
    expect([...pruneSelection(selection, (path) => present.has(path))]).toEqual(["a.ts", "b.ts"]);
    expect(pruneSelection(selection, () => true)).toBe(selection);
    expect(pruneSelection(EMPTY_SELECTION, () => false)).toBe(EMPTY_SELECTION);
    expect(pruneSelection(selection, () => false).size).toBe(0);
  });

  test("the select-all state is none, some, or all of the visible paths", () => {
    const visible = ["a.ts", "b.ts", "c.ts"];
    expect(selectAllState(EMPTY_SELECTION, visible)).toBe("none");
    expect(selectAllState(new Set(["a.ts"]), visible)).toBe("some");
    expect(selectAllState(new Set(["a.ts", "b.ts", "c.ts"]), visible)).toBe("all");
    // Paths selected but filtered out of view do not count.
    expect(selectAllState(new Set(["hidden.ts"]), visible)).toBe("none");
    expect(selectAllState(new Set(["a.ts", "b.ts", "c.ts", "hidden.ts"]), visible)).toBe("all");
    // Nothing visible is never "all".
    expect(selectAllState(new Set(["a.ts"]), [])).toBe("none");
    // Unchecked selects everything visible; some or all clears.
    expect(selectAllToggleSelects("none")).toBe(true);
    expect(selectAllToggleSelects("some")).toBe(false);
    expect(selectAllToggleSelects("all")).toBe(false);
  });

  test("a shift-click range runs between the anchor and the target in list order, either way round", () => {
    const order = ["a", "b", "c", "d", "e"];
    expect(pathsInRange(order, "b", "d")).toEqual(["b", "c", "d"]);
    expect(pathsInRange(order, "d", "b")).toEqual(["b", "c", "d"]);
    expect(pathsInRange(order, "c", "c")).toEqual(["c"]);
    // No anchor, or one no longer listed: the target alone.
    expect(pathsInRange(order, null, "d")).toEqual(["d"]);
    expect(pathsInRange(order, "gone", "d")).toEqual(["d"]);
    // A target outside the list (a stale row) is still just itself.
    expect(pathsInRange(order, "a", "zzz")).toEqual(["zzz"]);
  });

  test("the visible files are every file, or the search's matches that are files", () => {
    const files = ["src/a.ts", "src/b.ts", "README.md"];
    expect(visibleFilePaths(files, null)).toEqual(files);
    expect(visibleFilePaths(files, null)).not.toBe(files);
    // The search reports folders among its matches; only files are selectable.
    expect(visibleFilePaths(files, ["src", "src/a.ts", "src/b.ts"])).toEqual([
      "src/a.ts",
      "src/b.ts",
    ]);
    expect(visibleFilePaths(files, [])).toEqual([]);
  });
});
