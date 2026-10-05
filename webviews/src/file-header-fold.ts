// A double-click on a file card's header band folds the card. The band is
// Pierre's `[data-diffs-header]` inside the card's (`diffs-container`) shadow
// root, so the App listens above the card and reads the event's composed
// path. Everything DOM-facing here is a pure function of that path, so it is
// testable without the card.

/** The attribute the App's fold chevron carries naming the card's item. */
export const FOLD_ITEM_ATTRIBUTE = "data-item-id";

/**
 * Elements whose double-click is their own: the fold chevron, the selection
 * checkbox, the write actions, the Viewed control, a link in a comment.
 * Their two clicks already ran; the double-click that follows must not fold
 * the card on top of them.
 */
const CONTROL_SELECTOR = "button, input, a, select, textarea, summary, [role], [contenteditable]";

/**
 * The id of the item whose header band `path` (a `dblclick` event's
 * `composedPath()`) double-clicked, or `null` when the double-click was not
 * on a header band, or landed on a control inside it.
 *
 * The path is walked from the target outward. Before the header band, a
 * control ends the walk: the band's own controls are slotted light DOM, so
 * they precede the band in the path (through their slot). Past the band,
 * the card host names the item: Pierre pools and reuses its host elements
 * and puts nothing on them naming the item, while the light DOM it slots
 * into the host is re-rendered for the item currently shown, so the App's
 * fold chevron there carries the item id as `FOLD_ITEM_ATTRIBUTE`.
 */
export function foldTargetFromComposedPath(
  path: ReadonlyArray<EventTarget | null | undefined>,
): string | null {
  let pastHeader = false;
  for (const node of path) {
    if (node == null || !isElement(node)) {
      continue;
    }
    if (!pastHeader) {
      if (node.hasAttribute("data-diffs-header")) {
        pastHeader = true;
      } else if (node.matches(CONTROL_SELECTOR)) {
        return null;
      }
      continue;
    }
    if (node.localName === "diffs-container") {
      return node.querySelector(`.file-collapse-toggle[${FOLD_ITEM_ATTRIBUTE}]`)?.getAttribute(FOLD_ITEM_ATTRIBUTE) ?? null;
    }
  }
  return null;
}

/** Duck-typed: the DOM in tests comes from another realm than `Element`. */
function isElement(node: EventTarget): node is Element {
  return (node as Node).nodeType === 1 && typeof (node as Element).matches === "function";
}
