// The file list's per-row checkbox, drawn inside Pierre's file tree. The
// tree renders its rows itself (Preact, in a shadow root) and offers one
// custom lane per row, the "decoration", which shows an icon or text: the
// checkbox is an icon from a custom sprite sheet, chosen per row from the
// current selection. Clicks and Space on that lane are caught before the
// tree sees them (capture phase on the host), so checking a row never
// navigates to it. Everything DOM-facing here is a pure function of the
// event's composed path, so it is testable without the tree.

import type { FileTreeRowDecoration } from "@pierre/trees";

export const SELECTION_ICON_ON = "cmux-select-on";
export const SELECTION_ICON_OFF = "cmux-select-off";

/**
 * Symbols for the two checkbox states. Stroked in `currentColor` like the
 * viewer's own icons; the tree's `unsafeCSS` sizes and colors the lane.
 */
export const FILE_TREE_SELECTION_SPRITE = `<svg xmlns="http://www.w3.org/2000/svg" style="display:none" aria-hidden="true">
  <symbol id="${SELECTION_ICON_OFF}" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">
    <rect x="4" y="4" width="12" height="12" rx="2.5" />
  </symbol>
  <symbol id="${SELECTION_ICON_ON}" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">
    <rect x="4" y="4" width="12" height="12" rx="2.5" />
    <path d="m7 10.2 2.2 2.2L13.3 8" stroke-width="1.6" />
  </symbol>
</svg>`;

/** The decoration for one file row: its checkbox glyph and accessible name. */
export function selectionDecoration(
  selected: boolean,
  title: string,
): FileTreeRowDecoration {
  return {
    icon: {
      name: selected ? SELECTION_ICON_ON : SELECTION_ICON_OFF,
      width: 14,
      height: 14,
      viewBox: "0 0 20 20",
    },
    title,
  };
}

/**
 * The file path of the row whose decoration lane the event hit, or `null`
 * when the click landed anywhere else (the row's name, a folder, the
 * search box). Pierre marks the lane `data-item-section="decoration"` and
 * the row button `data-item-path` / `data-item-type`.
 */
export function selectionRowPathFromComposedPath(
  composedPath: ReadonlyArray<EventTarget | null | undefined>,
): string | null {
  let sawDecoration = false;
  for (const node of composedPath) {
    if (!(node instanceof Element)) {
      continue;
    }
    if (node.getAttribute("data-item-section") === "decoration") {
      sawDecoration = true;
      continue;
    }
    const rowPath = fileRowPath(node);
    if (rowPath != null) {
      return sawDecoration ? rowPath : null;
    }
  }
  return null;
}

/**
 * The file path of a focused row button (the keyboard target of Space), or
 * `null` for anything else, including a folder row or the search input.
 */
export function focusedFileRowPath(
  target: EventTarget | null | undefined,
): string | null {
  return target instanceof Element ? fileRowPath(target) : null;
}

function fileRowPath(node: Element): string | null {
  if (node.getAttribute("data-item-type") !== "file") {
    return null;
  }
  const path = node.getAttribute("data-item-path");
  return path == null || path === "" ? null : path;
}

/** Whether a keydown is a plain Space: the row-checkbox toggle, no modifiers. */
export function isPlainSpace(event: {
  key: string;
  altKey: boolean;
  ctrlKey: boolean;
  metaKey: boolean;
  shiftKey: boolean;
}): boolean {
  return (
    (event.key === " " || event.key === "Spacebar") &&
    !event.altKey &&
    !event.ctrlKey &&
    !event.metaKey &&
    !event.shiftKey
  );
}
