// Shared context-menu builders (③) so the tree, grid and rail show the
// SAME themed PopupMenu for a workspace header (layout-engine picker) and
// a window (ops menu). Each view supplies its own snapshot + hit point;
// the backend round-trip + menu data are identical, so they live here in
// the shared FacetView layer rather than duplicated three times.
//
// Every menu is built from grouped `Entry` rows via `present(...)`, which
// inserts a dim SECTION HEADER each time the section name changes — even a
// single group gets a header (item 4) — and attaches a per-row SF Symbol
// icon (item 7). Section headers + icons are skipped on the `filterable`
// (`m`-key) path, where the type-to-filter box does the organising.

import AppKit
import FacetCore

@MainActor
public enum ViewContextMenu {

    // MARK: - Sectioned menu plumbing

    /// One logical menu row before sectioning. `section` groups rows under
    /// a dim header; `icon` is an `IconResolver` spec (`SF:<name>`, "" =
    /// none). `checked` marks the current value (the ✓ row). `run` fires
    /// on pick.
    private struct Entry {
        let label: String
        let icon: String
        let section: String
        var checked: Bool = false
        /// Explicit tint override (e.g. destructive Close → `error`).
        /// `nil` = take the section default (item 10: layout→primary,
        /// tag→secondary, else neutral).
        var tint: NSColor? = nil
        let run: () -> Void
    }

    /// item 10 colour scheme: layout rows draw in the `primary` accent,
    /// tag rows in `secondary`; every other section stays neutral (the
    /// menu's default current/foreground rule). An `Entry.tint` overrides.
    private static func sectionTint(_ section: String,
                                    _ palette: ResolvedPalette) -> NSColor? {
        switch section {
        case "Layout": return palette.primary
        case "Tags":   return palette.secondary
        default:       return nil
        }
    }

    /// Build a `PopupMenu` payload from grouped `entries` and show it.
    /// Inserts a section-label row whenever the section name changes (a
    /// blank section name = a bare row, no header); tracks those rows in
    /// `headerRows` so the menu draws them dim + skips them in nav. Maps
    /// the popup's pick index back to the entry's `run`. On the
    /// `filterable` path the headers are omitted (the filter box replaces
    /// grouping), so the rows stay a flat, fully-pickable list.
    private static func present(at scr: NSPoint, header: String,
                                palette: ResolvedPalette,
                                filterable: Bool = false,
                                entries: [Entry]) {
        var items: [String] = []
        var icons: [String] = []
        var tints: [NSColor?] = []
        var headerRows: Set<Int> = []
        var checked: Int?
        var runByIndex: [Int: () -> Void] = [:]
        var last: String?
        for e in entries {
            // Section header whenever the section changes — shown even on the
            // filterable path now (PopupMenu keeps headers whose group has a
            // match), so grouped menus stay grouped while filtering.
            if e.section != last, !e.section.isEmpty {
                headerRows.insert(items.count)
                items.append(e.section)        // PopupMenu uppercases headers
                icons.append("")
                // Tint the section LABEL by its scheme too (TAGS→secondary,
                // LAYOUT→primary) so tag-related text reads secondary; other
                // sections fall back to the menu's dim header colour.
                tints.append(sectionTint(e.section, palette))
            }
            last = e.section
            if e.checked { checked = items.count }
            runByIndex[items.count] = e.run
            items.append(e.label)
            icons.append(e.icon)
            tints.append(e.tint ?? sectionTint(e.section, palette))
        }
        PopupMenu.shared.show(at: scr,
                              header: header,
                              items: items,
                              checkedIndex: checked,
                              palette: palette,
                              filterable: filterable,
                              headerRows: headerRows,
                              icons: icons,
                              rowTints: tints) { i in
            runByIndex[i]?()
        }
    }

    // MARK: - Builders

    /// Layout-engine picker for a workspace header. `ws` is the 0-based
    /// workspace index; `workspaces` the view's current snapshot (for the
    /// checkmark on the active mode).
    public static func showLayout(
        at scr: NSPoint,
        backend: any WindowBackend,
        workspaceIndex ws: Int,
        workspaces: [Workspace],
        palette: ResolvedPalette,
        filterable: Bool = false,
        tagMode: Bool = false
    ) {
        // Tag mode shows ONE global layout for the tag-world's lens union;
        // only tag-compatible modes apply (float + stateless engines —
        // bsp / stack are workspace-only). Filter them out so the picker
        // never offers a mode `setLayoutMode` would reject.
        let modes = tagMode
            ? backend.layoutModes.filter {
                LayoutGrouping.isCompatible(mode: $0, with: .tag) }
            : backend.layoutModes
        let cur = workspaces.first { $0.index == ws }?.layoutMode
        let header = tagMode ? "Tag-world" : "WS\(ws + 1)"
        let entries = modes.map { mode in
            Entry(label: mode, icon: layoutModeIcon(mode),
                  section: "Layout", checked: mode == cur) {
                cliQueue.async { backend.setLayoutMode(workspaceIndex: ws, mode: mode) }
            }
        }
        present(at: scr, header: header, palette: palette,
                filterable: filterable, entries: entries)
    }

    /// Panel-level menu for the pinned "Desktop N" band — the third
    /// right-click surface (scope hierarchy: panel ▸ workspace ▸ window).
    /// Exposes the tree-wide keyboard modes that are otherwise reachable
    /// only by entering keyboard nav: Search (the `s` key) always, and Manage
    /// tags (the `t` key) only under tag grouping. Picking an item runs its
    /// callback, which self-activates facet — no window is focused, so the
    /// #66 same-app-focus invariant and the never-steal-focus contract both
    /// hold (contrast a window-row click, which must NOT grab key).
    public static func showDesktop(
        at scr: NSPoint,
        palette: ResolvedPalette,
        tagManage: Bool,
        ordinal: Int? = nil,
        onSearch: @escaping () -> Void,
        onTagManage: @escaping () -> Void
    ) {
        var entries: [Entry] = [
            Entry(label: "Search", icon: "SF:magnifyingglass",
                  section: "Find", run: onSearch),
        ]
        if tagManage {
            entries.append(Entry(label: "Manage tags", icon: "SF:tag",
                                 section: "Tags", run: onTagManage))
        }
        // Title carries the mac-desktop number (matching the pinned
        // "Desktop N" band the menu pops from); bare "Desktop" if unknown.
        let header = ordinal.map { "Desktop \($0)" } ?? "Desktop"
        present(at: scr, header: header, palette: palette, entries: entries)
    }

    /// Tag-world header menu (tag mode). Title-less (item 13 — the section
    /// labels carry the context) and type-to-filter like the other context
    /// menus (item 11). Grouped sections:
    ///
    ///     LAYOUT          ← section (primary accent)
    ///     float · grid · master-… (the tag-compatible modes, current ✓)
    ///     TAGS            ← section (secondary accent)
    ///     Select tags     → opens the lens checklist
    ///     All tags        → lens = every tag (show everything; item 15/16)
    ///
    /// `layoutModes` is already filtered to tag-compatible engines. The
    /// workspace-header menu (`showLayout`) stays the bare layout picker
    /// (no lens in workspace mode).
    public static func showTagWorld(
        at scr: NSPoint,
        layoutModes: [String],
        currentLayout: String?,
        palette: ResolvedPalette,
        onPickLayout: @escaping (String) -> Void,
        onSelectTags: @escaping () -> Void,
        onAllTags: @escaping () -> Void
    ) {
        var entries = layoutModes.map { mode in
            Entry(label: mode, icon: layoutModeIcon(mode),
                  section: "Layout", checked: mode == currentLayout) {
                onPickLayout(mode)
            }
        }
        entries.append(Entry(label: "Select tags",
                             icon: "SF:line.3.horizontal.decrease.circle",
                             section: "Tags", run: onSelectTags))
        entries.append(Entry(label: "All tags", icon: "SF:tag",
                             section: "Tags", run: onAllTags))
        present(at: scr, header: "", palette: palette,
                filterable: true, entries: entries)
    }

    /// Window-ops menu for a window (close / float / master / stack /
    /// sticky, gated by the window's state). `runOps` runs the chosen
    /// non-close ops against the window — the caller threads it to the
    /// controller's `runWindowOps` (close goes straight to the backend).
    public static func showWindow(
        at scr: NSPoint,
        backend: any WindowBackend,
        workspaceIndex ws: Int,
        workspaces: [Workspace],
        pid: Int,
        windowID id: WindowID,
        title: String,
        palette: ResolvedPalette,
        tagMode: Bool = false,
        filterable: Bool = false,
        addToLensTargets: [(label: String, sectionID: String)] = [],
        onApplyAdd: ((_ sectionID: String) -> Void)? = nil,
        onOpenTagEditor: ((_ id: WindowID, _ pid: Int, _ appName: String,
                           _ title: String, _ currentTags: [String],
                           _ anchor: NSPoint) -> Void)? = nil,
        runOps: @escaping (_ ops: [WindowAction], _ window: Window, _ ws: Int) -> Void
    ) {
        let wsModel = workspaces.first { $0.index == ws }
        let mode = wsModel?.layoutMode ?? ""
        let win = wsModel?.windows.first { $0.id == id }
        let floating = win?.isFloating ?? false
        let isMaster = win?.isMaster ?? false
        let isSticky = win?.isSticky ?? false
        // Non-floating tiled members — what stack cycling rotates over.
        let windowCount = wsModel?.windows.filter { !$0.isFloating }.count ?? 0
        let menu = backend.windowMenu(mode: mode, floating: floating,
                                      isMaster: isMaster,
                                      windowCount: windowCount,
                                      isSticky: isSticky)
        // Each backend item carries its own icon + section. Order the menu
        // LAYOUT → TAG → ACTION (item 12): tiling ops first, the per-window
        // Tag in the middle, then the window-state / destructive actions.
        func makeEntry(_ item: WindowMenuItem) -> Entry {
            // Close is destructive → `error` (red) accent (item 10: the
            // Action section is otherwise neutral, so the danger reads).
            Entry(label: item.label, icon: item.icon, section: item.section,
                  tint: item.isClose ? palette.error : nil) {
                if item.isClose {
                    cliQueue.async { backend.closeWindow(id) }
                } else {
                    let window = Window(id: id, pid: pid, appName: "",
                                        title: title, isFocused: false,
                                        isFloating: floating, frame: nil)
                    runOps(item.ops, window, ws)
                }
            }
        }
        var entries = menu.filter { $0.section == "Layout" }.map(makeEntry)
        // Tag mode (#4): a single "Tag" item under its own TAGS section that
        // opens the per-window tag-edit checklist (`TagEditPanel`). Grid /
        // rail are workspace-only in tag mode, so they never set `tagMode`
        // and this item never appears there.
        if tagMode {
            entries.append(Entry(label: "Tag", icon: "SF:tag",
                                 section: "Tags") {
                onOpenTagEditor?(id, pid, win?.appName ?? "",
                                 win?.title ?? title, win?.tags ?? [], scr)
            })
        }
        // Section model (PR8): "Add to <lens>" items — apply-only ADD
        // (multi-match: the window joins the lens, staying in every section it
        // already matched). Their own section so they read as a group. Grid /
        // rail pass an empty list → no section appears.
        if !addToLensTargets.isEmpty, let onApplyAdd {
            for t in addToLensTargets {
                entries.append(Entry(label: "Add to \(t.label)", icon: "SF:tag",
                                     section: "Add to lens") {
                    onApplyAdd(t.sectionID)
                })
            }
        }
        entries += menu.filter { $0.section != "Layout" }.map(makeEntry)
        present(at: scr, header: "Window", palette: palette,
                filterable: filterable, entries: entries)
    }
}
