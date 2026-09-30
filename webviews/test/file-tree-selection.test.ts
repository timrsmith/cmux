import { afterEach, describe, expect, test } from "bun:test";
import {
  FILE_TREE_SELECTION_SPRITE,
  SELECTION_ICON_OFF,
  SELECTION_ICON_ON,
  focusedFileRowPath,
  isPlainSpace,
  selectionDecoration,
  selectionRowPathFromComposedPath,
} from "../src/file-tree-selection";
import { mountDom, resetDom } from "./support/dom";

afterEach(resetDom);

/** A Pierre row as the tree renders it: name, decoration lane, git lane. */
function row(document: Document, kind: "file" | "directory", path: string) {
  const button = document.createElement("button");
  button.setAttribute("data-item-type", kind);
  button.setAttribute("data-item-path", path);
  const content = document.createElement("div");
  content.setAttribute("data-item-section", "content");
  content.textContent = path;
  const decoration = document.createElement("div");
  decoration.setAttribute("data-item-section", "decoration");
  const glyph = document.createElement("span");
  decoration.append(glyph);
  const git = document.createElement("div");
  git.setAttribute("data-item-section", "git");
  button.append(content, decoration, git);
  document.body.append(button);
  return { button, content, decoration, glyph, git };
}

/** The composed path of an event at `target`: target first, then ancestors. */
function composedPathOf(target: Element): EventTarget[] {
  const path: EventTarget[] = [];
  for (let node: Element | null = target; node != null; node = node.parentElement) {
    path.push(node);
  }
  path.push(target.ownerDocument, target.ownerDocument.defaultView!);
  return path;
}

describe("file tree row checkboxes", () => {
  test("the sprite carries both checkbox glyphs the decoration names", () => {
    expect(FILE_TREE_SELECTION_SPRITE).toContain(`id="${SELECTION_ICON_ON}"`);
    expect(FILE_TREE_SELECTION_SPRITE).toContain(`id="${SELECTION_ICON_OFF}"`);
    expect(selectionDecoration(true, "Select a.ts")).toEqual({
      icon: { name: SELECTION_ICON_ON, width: 14, height: 14, viewBox: "0 0 20 20" },
      title: "Select a.ts",
    });
    expect(selectionDecoration(false, "Select a.ts")).toMatchObject({
      icon: { name: SELECTION_ICON_OFF },
      title: "Select a.ts",
    });
  });

  test("a click resolves to the row only when it lands on the decoration lane of a file row", () => {
    const dom = mountDom();
    const document = dom.window.document;
    const file = row(document, "file", "src/a.ts");
    const folder = row(document, "directory", "src");
    expect(selectionRowPathFromComposedPath(composedPathOf(file.glyph))).toBe("src/a.ts");
    expect(selectionRowPathFromComposedPath(composedPathOf(file.decoration))).toBe("src/a.ts");
    // The name, the git lane, or the row itself: the tree's own click.
    expect(selectionRowPathFromComposedPath(composedPathOf(file.content))).toBeNull();
    expect(selectionRowPathFromComposedPath(composedPathOf(file.git))).toBeNull();
    expect(selectionRowPathFromComposedPath(composedPathOf(file.button))).toBeNull();
    // A folder's lane is never a checkbox.
    expect(selectionRowPathFromComposedPath(composedPathOf(folder.glyph))).toBeNull();
    // Non-element entries (document, window, null) are skipped.
    expect(selectionRowPathFromComposedPath([null, undefined, document])).toBeNull();
    expect(selectionRowPathFromComposedPath([])).toBeNull();
  });

  test("Space targets the focused file row and nothing else", () => {
    const dom = mountDom();
    const document = dom.window.document;
    const file = row(document, "file", "src/a.ts");
    const folder = row(document, "directory", "src");
    const input = document.createElement("input");
    expect(focusedFileRowPath(file.button)).toBe("src/a.ts");
    expect(focusedFileRowPath(folder.button)).toBeNull();
    expect(focusedFileRowPath(file.content)).toBeNull();
    expect(focusedFileRowPath(input)).toBeNull();
    expect(focusedFileRowPath(null)).toBeNull();
    expect(focusedFileRowPath(undefined)).toBeNull();
    const plain = { key: " ", altKey: false, ctrlKey: false, metaKey: false, shiftKey: false };
    expect(isPlainSpace(plain)).toBe(true);
    expect(isPlainSpace({ ...plain, key: "Spacebar" })).toBe(true);
    // Cmd/Ctrl+Space is the tree's own multi-select; Shift+Space and Enter are not the checkbox.
    expect(isPlainSpace({ ...plain, metaKey: true })).toBe(false);
    expect(isPlainSpace({ ...plain, ctrlKey: true })).toBe(false);
    expect(isPlainSpace({ ...plain, shiftKey: true })).toBe(false);
    expect(isPlainSpace({ ...plain, altKey: true })).toBe(false);
    expect(isPlainSpace({ ...plain, key: "Enter" })).toBe(false);
  });
});
