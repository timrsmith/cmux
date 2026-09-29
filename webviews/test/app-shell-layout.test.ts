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

  test("the toolbar is a single row when the repository header hosts the pickers", () => {
    // The two-row stacking at narrow widths applies only to a bar that still
    // hosts the source controls; without them the bar keeps two columns.
    expect(
      declaration(
        '#toolbar[data-hosts-source="false"]',
        "grid-template-columns",
      ),
    ).toBe("minmax(0, 1fr) minmax(0, auto)");
    // The 760px block (up to its closing brace at column 0) scopes every rule
    // to the bar that hosts the pickers.
    const narrow = /@media \(max-width: 760px\) \{([\s\S]*?)\n\}/.exec(
      css,
    )?.[1];
    expect(narrow).toBeDefined();
    expect(narrow).toMatch(
      /#toolbar\[data-hosts-source="true"\]\s*\{[^}]*grid-template-areas:/s,
    );
    expect(narrow).not.toMatch(/\n\s*#toolbar\s*\{/);
    expect(narrow).not.toMatch(/\n\s*\.toolbar-(left|middle|actions)\s*\{/);
  });

  test("the header and toolbar read as one block with one bottom border", () => {
    expect(declaration("#repo-header", "border-bottom")).toBeUndefined();
    expect(declaration("#repo-header", "background")).toBe(
      "var(--cmux-diff-toolbar-bg)",
    );
    expect(declaration("#toolbar", "border-bottom")).toBe(
      "1px solid var(--cmux-diff-border)",
    );
    // The header's menus and popovers drop over the toolbar, so the header
    // stacks above it.
    expect(Number(declaration("#repo-header", "z-index"))).toBeGreaterThan(
      Number(declaration("#toolbar", "z-index")),
    );
  });
});
