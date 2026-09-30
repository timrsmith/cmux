import { Icon, type IconName } from "./icons";
import type { DiffViewerLabelKey, DiffViewerLabelResolver } from "./labels";
import type { DiffViewerOptions } from "./pierre-options";

/**
 * The view options every diff session offers: word wrap, collapse all,
 * unified/split, the source URL, the files list, unchanged context,
 * backgrounds, line numbers, word diffs, and the indicator style. The
 * toolbar's "..." menu (patch and branch sessions) and the repository
 * header's "..." menu (working-tree sessions) both render this one list, so
 * the items, their labels, and the actions they dispatch live in one place.
 */

export type DiffViewerLayout = DiffViewerOptions["layout"];

/**
 * Sets one view option. The reducer applies it as `options[key] = value`, so
 * each key pairs with its own value type (a layout for `layout`, a boolean
 * for `wordWrap`) rather than any value for any key.
 */
export type SetOptionAction = {
  [K in keyof DiffViewerOptions]: {
    type: "set-option";
    key: K;
    value: DiffViewerOptions[K];
  };
}[keyof DiffViewerOptions];

/** The App reducer actions a view option dispatches. */
export type ViewOptionAction =
  | SetOptionAction
  | { type: "set-files-visible"; visible: boolean };

/** The options a menu row switches on and off. */
type BooleanOptionKey = {
  [K in keyof DiffViewerOptions]: DiffViewerOptions[K] extends boolean
    ? K
    : never;
}[keyof DiffViewerOptions];

/** The indicator styles of the segmented control, with their icon and label. */
const INDICATOR_STYLES = [
  { value: "bars", icon: "bars", labelKey: "bars" },
  { value: "classic", icon: "classic", labelKey: "classic" },
  { value: "none", icon: "eye", labelKey: "none" },
] as const satisfies ReadonlyArray<{
  value: DiffViewerOptions["diffIndicators"];
  icon: IconName;
  labelKey: DiffViewerLabelKey;
}>;

export function ViewOptionsMenuItems({
  dispatch,
  externalURL,
  filesVisible,
  label,
  onSetLayout,
  options,
}: {
  dispatch: (action: ViewOptionAction) => void;
  externalURL: string | null;
  filesVisible: boolean;
  label: DiffViewerLabelResolver;
  onSetLayout: (layout: DiffViewerLayout) => void;
  options: DiffViewerOptions;
}) {
  const toggle = (key: BooleanOptionKey) =>
    dispatch({ type: "set-option", key, value: !options[key] });
  return (
    <>
      <MenuButton
        checked={options.wordWrap}
        icon="wrap"
        label={
          options.wordWrap ? label("disableWordWrap") : label("enableWordWrap")
        }
        onClick={() => toggle("wordWrap")}
      />
      <MenuButton
        checked={options.collapsed}
        icon={options.collapsed ? "expand" : "collapse"}
        label={
          options.collapsed
            ? label("expandAllDiffs")
            : label("collapseAllDiffs")
        }
        onClick={() => toggle("collapsed")}
      />
      <MenuButton
        icon={options.layout}
        label={
          options.layout === "split"
            ? label("switchToUnifiedDiff")
            : label("switchToSplitDiff")
        }
        onClick={() =>
          onSetLayout(options.layout === "split" ? "unified" : "split")
        }
      />
      {externalURL ? (
        <MenuButton
          icon="external"
          label={label("openSourceURL")}
          onClick={() => window.open(externalURL, "_blank", "noreferrer")}
        />
      ) : null}
      <MenuButton
        checked={filesVisible}
        icon="files"
        label={filesVisible ? label("hideFiles") : label("showFiles")}
        onClick={() =>
          dispatch({ type: "set-files-visible", visible: !filesVisible })
        }
      />
      <MenuButton
        checked={options.expandUnchanged}
        icon="document"
        label={
          options.expandUnchanged
            ? label("collapseUnchangedContext")
            : label("expandUnchangedContext")
        }
        onClick={() => toggle("expandUnchanged")}
      />
      <MenuButton
        checked={options.showBackgrounds}
        icon="background"
        label={
          options.showBackgrounds
            ? label("hideBackgrounds")
            : label("showBackgrounds")
        }
        onClick={() => toggle("showBackgrounds")}
      />
      <MenuButton
        checked={options.lineNumbers}
        icon="numbers"
        label={
          options.lineNumbers
            ? label("hideLineNumbers")
            : label("showLineNumbers")
        }
        onClick={() => toggle("lineNumbers")}
      />
      <MenuButton
        checked={options.wordDiffs}
        icon="word"
        label={
          options.wordDiffs
            ? label("disableWordDiffs")
            : label("enableWordDiffs")
        }
        onClick={() => toggle("wordDiffs")}
      />
      <div className="menu-item menu-segment">
        <Icon name="bars" />
        <span className="menu-label">{label("indicatorStyle")}</span>
        <span className="menu-segment-controls">
          {INDICATOR_STYLES.map((option) => (
            <button
              key={option.value}
              type="button"
              className="segment-button"
              title={label(option.labelKey)}
              aria-label={label(option.labelKey)}
              aria-pressed={options.diffIndicators === option.value}
              onClick={() => dispatch({ type: "set-option", key: "diffIndicators", value: option.value })}
            >
              <Icon name={option.icon} />
            </button>
          ))}
        </span>
      </div>
    </>
  );
}

/**
 * One row of a "..." menu. A toggle passes `checked` (rendered as
 * `aria-pressed` plus the check mark); a repository action passes `action`
 * (its `data-action` hook for tests and CSS) and `danger` for a destructive
 * one.
 */
export function MenuButton({
  action,
  checked,
  danger,
  disabled,
  icon,
  label,
  onClick,
  title,
}: {
  action?: string;
  checked?: boolean;
  danger?: boolean;
  disabled?: boolean;
  icon: IconName;
  label: string;
  onClick: () => void;
  title?: string;
}) {
  return (
    <button
      type="button"
      className="menu-item"
      aria-pressed={checked == null ? undefined : checked}
      data-action={action}
      data-danger={danger ? "true" : undefined}
      disabled={disabled}
      title={title}
      onClick={onClick}
    >
      <Icon name={icon} />
      <span className="menu-label">{label}</span>
      <span className="menu-check">
        {checked ? <Icon name="check" /> : null}
      </span>
    </button>
  );
}
