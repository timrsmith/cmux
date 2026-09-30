import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

// The shell is a one-column grid with two rows: one top bar, the repository
// header (working-tree views) or the toolbar (every other session), then the
// content (diffs). A DOM test cannot observe layout, so this guards the rule
// set directly: a third row, or a child pinned to one, would put #content in
// the wrong track and the diff would disappear behind a centered header.
const css = readFileSync(
  join(import.meta.dir, "..", "src", "styles.css"),
  "utf8",
);

function declaration(selector: string, property: string): string | undefined {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const block = new RegExp(`(?:^|\\n)${escaped}\\s*\\{([^}]*)\\}`).exec(
    css,
  )?.[1];
  const match = block
    ? new RegExp(`(?:^|;|\\n)\\s*${property}\\s*:\\s*([^;]+);`).exec(block)
    : null;
  return match?.[1].trim();
}

describe("app shell grid", () => {
  test("declares one top bar row and one content row, with no child pinned", () => {
    expect(declaration("#app", "grid-template-rows")).toBe(
      "auto minmax(0, 1fr)",
    );
    // The header and the toolbar are mutually exclusive (the UI tests cover
    // that), so no shell child needs a `grid-row`.
    expect(css).not.toMatch(/#app\s*>\s*#[\w-]+\s*\{[^}]*grid-row/s);
  });

  test("the toolbar is a single row of pickers and actions with no file-jump track", () => {
    // The file list column owns file navigation, so the toolbar has only the
    // pickers (left) and the actions (right). A middle track, or a
    // narrow-width second row for it, would bring back the jump-to-file
    // control the sidebar already replaces.
    expect(declaration("#toolbar", "grid-template-columns")).toBe(
      "minmax(0, 1fr) minmax(0, auto)",
    );
    expect(css).not.toMatch(/#toolbar\s*\{[^}]*grid-template-areas/s);
    expect(css).not.toMatch(/\.toolbar-middle|#jump-select|#jump-search-button/);
  });

  test("the repository header summary never wraps and sheds detail by priority", () => {
    // A wrapped summary grew the header over the first file card. The
    // summary and status stay single-line; narrow headers hide the repo path
    // first and the ahead/behind position next, through container queries.
    expect(declaration(".repo-header-summary", "flex-wrap")).toBe("nowrap");
    expect(declaration(".repo-header-status", "flex-wrap")).toBe("nowrap");
    expect(declaration(".repo-header-status", "white-space")).toBe("nowrap");
    expect(declaration(".repo-header-source", "flex")).toBe("0 0 auto");
    expect(css).toMatch(/#repo-header\s*\{[^}]*container-type: inline-size;/s);
    const repoHidden = /@container \(max-width: 560px\) \{([\s\S]*?)\n\}/.exec(
      css,
    )?.[1];
    expect(repoHidden).toMatch(
      /\.repo-header-repo,\s*\.repo-header-separator\s*\{\s*display: none;/s,
    );
    const positionHidden =
      /@container \(max-width: 440px\) \{([\s\S]*?)\n\}/.exec(css)?.[1];
    expect(positionHidden).toMatch(/\.repo-header-position/);
  });

  test("whichever top row renders draws the block's bottom border on the same background", () => {
    for (const row of ["#repo-header", "#toolbar"]) {
      expect(declaration(row, "border-bottom")).toBe(
        "1px solid var(--cmux-diff-border)",
      );
      expect(declaration(row, "background")).toBe(
        "var(--cmux-diff-toolbar-bg)",
      );
    }
  });
});
