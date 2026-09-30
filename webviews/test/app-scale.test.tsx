import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderToStaticMarkup } from "react-dom/server";
import {
  closeFileSearch,
  FilesSidebarBackdrop,
  shouldDismissFileSearch,
} from "../src/App";
import { createDiffViewerLabelResolver } from "../src/labels";

test("mobile file drawer backdrop is an accessible close control", () => {
  const label = createDiffViewerLabelResolver(undefined);
  const markup = renderToStaticMarkup(
    <FilesSidebarBackdrop label={label} onClose={() => {}} open={true} />,
  );
  const dom = new JSDOM(markup);
  const backdrop = dom.window.document.getElementById("files-sidebar-backdrop");
  expect(backdrop?.tagName).toBe("BUTTON");
  expect(backdrop?.getAttribute("aria-controls")).toBe("files-sidebar");
  expect(backdrop?.getAttribute("aria-label")).toBe("Hide file search");
  dom.window.close();

  let closed = false;
  const control = FilesSidebarBackdrop({
    label,
    onClose: () => {
      closed = true;
    },
    open: true,
  }) as any;
  control.props.onClick();
  expect(closed).toBe(true);
  expect(FilesSidebarBackdrop({ label, onClose: () => {}, open: false })).toBeNull();
});

test("mobile file drawer dismisses Escape without changing wide search behavior", () => {
  expect(shouldDismissFileSearch("Escape", true)).toBe(true);
  expect(shouldDismissFileSearch("Escape", false)).toBe(false);
  expect(shouldDismissFileSearch("Enter", true)).toBe(false);

  // Closing the search hands focus back to the sidebar's search toggle.
  const dom = new JSDOM('<button id="file-search-toggle">Search</button>');
  const actions: any[] = [];
  closeFileSearch((action) => actions.push(action), dom.window.document);
  expect(actions).toEqual([{ type: "set-file-search-open", open: false }]);
  expect(dom.window.document.activeElement?.id).toBe("file-search-toggle");
  dom.window.close();
});
