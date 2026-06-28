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
        case "Layout":  return palette.primary
        // The section-rename row (header menus, §E) shares the per-window
        // Tags treatment — `secondary` — so non-layout actions read alike.
        case "Tags", "Section": return palette.secondary
        default:        return nil
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
    /// checkmark on the active mode). `header` is the §D `index (label)`
    /// caption composed by the caller (display ≠ `ws + 1` once lenses shift
    /// the section's tree position).
    public static func showLayout(
        at scr: NSPoint,
        backend: any WindowBackend,
        workspaceIndex ws: Int,
        workspaces: [Workspace],
        header: String,
        palette: ResolvedPalette,
        filterable: Bool = false,
        onRename: (() -> Void)? = nil
    ) {
        let modes = backend.layoutModes
        let cur = workspaces.first { $0.index == ws }?.layoutMode
        // §E: SECTION ▸ Rename above LAYOUT ▸ … (確定事項 #1). `present()`
        // inserts the dim group header when the section name changes, so the
        // single Rename row gets its own "SECTION" caption.
        var entries: [Entry] = []
        if let onRename {
            entries.append(Entry(label: "Rename", icon: "SF:pencil",
                                 section: "Section", run: onRename))
        }
        entries += modes.map { mode in
            Entry(label: mode, icon: layoutModeIcon(mode),
                  section: "Layout", checked: mode == cur) {
                cliQueue.async { backend.setLayoutMode(workspaceIndex: ws, mode: mode) }
            }
        }
        present(at: scr, header: header, palette: palette,
                filterable: filterable, entries: entries)
    }

    /// Rename-only header menu for a `type="lens"` OR `type="unassigned"`
    /// section. A lens is a pure VIEW (t-0021) — it tiles nothing, so it has no
    /// layout to pick; the orphan receptacle never had one either. Both headers
    /// therefore offer ONLY `SECTION ▸ Rename` (the same row the workspace
    /// `showLayout` puts above its LAYOUT group). `header` is the §D
    /// `index (label)` caption.
    public static func showSectionRenameMenu(
        at scr: NSPoint,
        header: String,
        palette: ResolvedPalette,
        filterable: Bool = false,
        onRename: @escaping () -> Void
    ) {
        // §E: SECTION ▸ Rename, identical shape to the layout pickers' rename
        // row (`present()` gives the single row its own dim "SECTION" caption).
        let entries: [Entry] = [
            Entry(label: "Rename", icon: "SF:pencil",
                  section: "Section", run: onRename),
        ]
        present(at: scr, header: header, palette: palette,
                filterable: filterable, entries: entries)
    }

    /// Panel-level menu for the pinned "Desktop N" band — the third
    /// right-click surface (scope hierarchy: panel ▸ workspace ▸ window).
    /// Exposes the tree-wide keyboard modes that are otherwise reachable
    /// only by entering keyboard nav: Search (the `s` key). Picking an item
    /// runs its callback, which self-activates facet — no window is focused,
    /// so the #66 same-app-focus invariant and the never-steal-focus contract
    /// both hold (contrast a window-row click, which must NOT grab key).
    public static func showDesktop(
        at scr: NSPoint,
        palette: ResolvedPalette,
        ordinal: Int? = nil,
        onSearch: @escaping () -> Void
    ) {
        let entries: [Entry] = [
            Entry(label: "Search", icon: "SF:magnifyingglass",
                  section: "Find", run: onSearch),
        ]
        // Title carries the mac-desktop number (matching the pinned
        // "Desktop N" band the menu pops from); bare "Desktop" if unknown.
        let header = ordinal.map { "Desktop \($0)" } ?? "Desktop"
        present(at: scr, header: header, palette: palette, entries: entries)
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
        filterable: Bool = false,
        onEditTags: ((_ pid: Int, _ id: WindowID, _ title: String, _ anchor: NSPoint) -> Void)? = nil,
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
        // Per-window tag editing (R10): a single "Tag…" item opens the tag
        // checklist panel (add / remove / create a tag ON this window). This
        // replaces the pivot-era "Add to <lens>" — which only applied a lens's
        // apply-set, conflating tags with lens membership. Its own "Tags"
        // section (→ secondary tint). Grid / rail pass nil → no item appears.
        if let onEditTags {
            // Open the tag panel at the SAME anchor the menu used (`scr` =
            // level with the row, the `m` height), not beside the tree top.
            entries.append(Entry(label: "Tag", icon: "SF:tag", section: "Tags") {
                onEditTags(pid, id, title, scr)
            })
        }
        entries += menu.filter { $0.section != "Layout" }.map(makeEntry)
        present(at: scr, header: "Window", palette: palette,
                filterable: filterable, entries: entries)
    }
}
