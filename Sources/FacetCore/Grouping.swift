// Window grouping paradigm (M11-3) — pure, unit-testable.
//
// facet groups windows one of two ways, chosen once at startup via
// `[grouping] by` and fixed for the session:
//
//   - `workspace` (default): one window belongs to one facet
//     workspace. The historical model.
//   - `tag`: one window carries a SET of tags; a `lens` (the current
//     view mask) shows the union of windows whose tags intersect it
//     (dwm-style `tags & viewmask`). Tags are a RUNTIME-editable
//     per-window set (#191, shipped): the config `[[tag]]` tables seed
//     only the startup vocabulary, then re-tagging is live + session-
//     only via `facet window --tag/--untag/--toggle-tag/--retag`,
//     vocabulary edits via `facet tag --add/--remove/--rename`, and the
//     lens is selected via `facet lens`. Nothing is frozen at window
//     appearance and nothing persists across restart.
//
// The value is an open vocabulary on purpose — a future grouping
// paradigm (e.g. scrollable columns) is one more case, mirroring the
// `--view NAME` symmetric pattern. An unknown `by` is a loud config
// error, never a silent fallback.

/// How facet groups windows. Chosen at startup (`[grouping] by`),
/// fixed for the session — change it and restart.
public enum Grouping: String, Sendable, Equatable, CaseIterable {
    case workspace
    case tag
}

/// Which `Grouping`s a layout mode is compatible with — the data
/// behind the Fail-Fast config check (`by=tag` + a `workspace`-only
/// layout refuses to start) and the CLI's loud `exit 2` on an
/// incompatible `--layout`.
///
/// Why a mode can be workspace-only: the stateful adapter layouts
/// (`bsp` / `stack`) thread a per-container tree keyed by workspace;
/// an arbitrary tag union has no single such container, so they can't
/// represent it. The stateless engines (`master-*` / `grid` /
/// `spiral`) recompute purely from the member set every snapshot, so
/// they're membership-agnostic and support both. `float` is
/// membership-agnostic too.
public enum LayoutGrouping {
    /// Groupings the layout `mode` supports. Registered stateless
    /// engines delegate to their own `supportedGroupings`; the
    /// stateful adapter modes (not in `LayoutRegistry`) are listed
    /// here. An unknown mode supports nothing (so a typo'd layout is
    /// incompatible with every grouping — caught by validation).
    public static func supported(forMode mode: String) -> Set<Grouping> {
        let key = mode.lowercased()
        if let engine = LayoutRegistry.engine(named: key) {
            return engine.supportedGroupings
        }
        switch key {
        case "bsp", "stack": return [.workspace]
        case "float":        return [.workspace, .tag]
        default:             return []
        }
    }

    /// Whether `mode` can be used under `grouping`.
    public static func isCompatible(mode: String,
                                    with grouping: Grouping) -> Bool {
        supported(forMode: mode).contains(grouping)
    }
}
