import { Icon, type IconName } from "./icons";
import type { DiffViewerLabelResolver } from "./labels";
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

/** The App reducer actions a view option dispatches. */
export type ViewOptionAction =
  | { type: "set-option"; key: keyof DiffViewerOptions; value: any }
  | { type: "set-files-visible"; visible: boolean };

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
  const toggle = (key: keyof DiffViewerOptions) =>
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
          {[
            { value: "bars", icon: "bars", label: label("bars") },
            { value: "classic", icon: "classic", label: label("classic") },
            { value: "none", icon: "eye", label: label("none") },
          ].map((option) => (
            <button
              key={option.value}
              type="button"
              className="segment-button"
              title={option.label}
              aria-label={option.label}
              aria-pressed={options.diffIndicators === option.value}
              onClick={() =>
                dispatch({
                  type: "set-option",
                  key: "diffIndicators",
                  value: option.value,
                })
              }
            >
              <Icon name={option.icon as IconName} />
            </button>
          ))}
        </span>
      </div>
    </>
  );
}

export function MenuButton({
  checked,
  disabled,
  icon,
  label,
  onClick,
  title,
}: {
  checked?: boolean;
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
