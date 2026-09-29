import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

// The shell is a one-column grid whose rows are the optional repository
// header (repo and its actions), the toolbar (file navigation), and the
// content (diffs). A DOM test cannot observe layout, so this guards the rule
// set directly: when a row is added to #app, the template and the pinned rows
// must move together, or #content lands in an implicit zero-height row and
// the diff disappears behind a centered header.
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
  test("declares one row per shell child and pins each child to its row", () => {
    expect(declaration("#app", "grid-template-rows")).toBe(
      "auto auto minmax(0, 1fr)",
    );
    expect(declaration("#app > #repo-header", "grid-row")).toBe("1");
    expect(declaration("#app > #toolbar", "grid-row")).toBe("2");
    expect(declaration("#app > #content", "grid-row")).toBe("3");
  });

  test("the toolbar keeps its two-row stacking at narrow widths for the sessions that render it", () => {
    // Working-tree views render the header instead of the toolbar, so the
    // toolbar never needs a header-mode variant: no host-dependent selector.
    expect(css).not.toContain("data-hosts-source");
    const narrow = /@media \(max-width: 760px\) \{([\s\S]*?)\n\}/.exec(
      css,
    )?.[1];
    expect(narrow).toBeDefined();
    expect(narrow).toMatch(/\n\s*#toolbar\s*\{[^}]*grid-template-areas:/s);
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
