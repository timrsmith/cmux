import { expect, test } from "bun:test";
import type { DiffViewerOptions } from "../src/pierre-options";
import type { ViewOptionAction } from "../src/ViewOptionsMenu";

// The reducer applies `set-option` as `options[key] = value`, so the action
// must pair each key with that key's value type: `bun run typecheck` is the
// assertion, the runtime test only keeps the file in the suite.

const wellTyped: ViewOptionAction[] = [
  { type: "set-option", key: "wordWrap", value: true },
  { type: "set-option", key: "layout", value: "split" },
  { type: "set-option", key: "diffIndicators", value: "classic" },
  { type: "set-files-visible", visible: false },
];

const mismatched: ViewOptionAction[] = [
  // @ts-expect-error a layout is not a boolean
  { type: "set-option", key: "wordWrap", value: "split" },
  // @ts-expect-error a boolean is not a layout
  { type: "set-option", key: "layout", value: true },
  // @ts-expect-error not an indicator style
  { type: "set-option", key: "diffIndicators", value: "dots" },
  // @ts-expect-error not an option
  { type: "set-option", key: "fontSize", value: 12 },
];

test("a set-option action carries the value type of its key", () => {
  const applied = { wordWrap: false } as Pick<DiffViewerOptions, "wordWrap">;
  for (const action of wellTyped) {
    if (action.type === "set-option" && action.key === "wordWrap") {
      // Narrowing on the key narrows the value: no cast needed.
      applied.wordWrap = action.value;
    }
  }
  expect(applied.wordWrap).toBe(true);
  expect(mismatched).toHaveLength(4);
});
