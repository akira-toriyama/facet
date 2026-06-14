// `facet query --windows` synthesis (#223), split across two phases so
// catalog access stays off the heavy path:
//
//   • `queryFacetStates()` — reads the catalog structs (active + parked)
//     into an immutable `[WindowID: FacetWindowState]` map. The catalog
//     is mutated by the DNC dispatch handlers on the MAIN actor (no
//     cliQueue hop), so this read MUST also run on main — the Controller
//     calls it on main, a quick read in the same risk class as
//     `stashedScratchpads()`. It touches none of the heavy OS APIs.
//
//   • `queryEntries(facetStates:)` — the heavy, catalog-FREE sweep:
//     `enumerateCGWindows()` (CGWindowList .optionAll → every real window
//     on every space), `MacDesktops.ordinalMap()` + `ids(forWindow:)` for
//     the desktop ordinal (`nil` when SkyLight is down / unresolvable),
//     and `AXTitles.resolve` for on-screen windows missing a title
//     (off-screen → "", to bound AX traffic). The Controller runs it
//     off-main on `cliQueue` (AXTitles is cliQueue-only by contract);
//     it merges the passed-in facet map by window id.
//
// Keeping the catalog read on main + the heavy sweep catalog-free means
// the off-main work never races the main-thread catalog mutators.
// Read-only / SIP-on throughout.

import AppKit
import FacetCore
import FacetAccessibility

extension NativeAdapter {

    public func queryFacetStates()
        -> [WindowID: WindowQueryEntry.FacetWindowState]
    {
        var out: [WindowID: WindowQueryEntry.FacetWindowState] = [:]
        // Parked catalogs first, then the active catalog OVERWRITES — so
        // if a window moved to the active desktop but a stale parked
        // snapshot still lists it, the active (authoritative) state wins.
        for cat in parkedCatalogs.values {
            for id in cat.windowMap.keys {
                out[id] = facetState(forWindow: id, in: cat)
            }
        }
        for id in catalog.windowMap.keys {
            out[id] = facetState(forWindow: id, in: catalog)
        }
        return out
    }

    public func queryEntries(facetStates:
        [WindowID: WindowQueryEntry.FacetWindowState]) -> [WindowQueryEntry]
    {
        let live = enumerateCGWindows()
        guard !live.isEmpty else { return [] }

        let ordMap = MacDesktops.ordinalMap()
        let focused = focusedWindow()

        // AX-resolve titles only for on-screen windows whose CGWindow
        // title is empty (off-screen → "" best-effort). Wrap them in a
        // throwaway Workspace so the batched-by-pid resolver can run.
        let needTitle = live.filter { $0.isOnscreen && $0.title.isEmpty }
        let axTitles: [WindowID: String] = needTitle.isEmpty
            ? [:]
            : AXTitles.resolve([Workspace(index: 0, name: "",
                                          isActive: true, layoutMode: "float",
                                          windows: needTitle)])

        var entries: [WindowQueryEntry] = live.map { w in
            let desktop: Int? = MacDesktops.ids(forWindow: w.id.serverID)
                .lazy.compactMap { ordMap[$0] }.first
            let title = !w.title.isEmpty
                ? w.title
                : (w.isOnscreen ? (axTitles[w.id] ?? "") : "")
            let frame = w.frame.map {
                WindowQueryEntry.Frame(
                    x: Int($0.origin.x), y: Int($0.origin.y),
                    w: Int($0.size.width), h: Int($0.size.height))
            }
            return WindowQueryEntry(
                id: w.id.serverID, pid: w.pid, app: w.appName,
                title: title, bundleId: w.bundleId, desktop: desktop,
                frame: frame, onscreen: w.isOnscreen,
                focused: w.id == focused,
                facet: facetStates[w.id])
        }

        // Stable, grep/diff-friendly order: desktop ordinal → facet
        // workspace index → window id. Unknown desktop / unmanaged sort
        // last (Int.max).
        entries.sort { a, b in
            let da = a.desktop ?? .max, db = b.desktop ?? .max
            if da != db { return da < db }
            let wa = a.facet?.workspaceIndex ?? .max
            let wb = b.facet?.workspaceIndex ?? .max
            if wa != wb { return wa < wb }
            return a.id < b.id
        }
        return entries
    }

    /// facet's state for `id` within one catalog. `nil` when the window
    /// isn't in that catalog's `windowMap`.
    private func facetState(forWindow id: WindowID, in cat: WorkspaceCatalog)
        -> WindowQueryEntry.FacetWindowState?
    {
        guard let slot = cat.windowMap[id] else { return nil }
        let idx = slot.workspace
        let name = (idx >= 1 && idx <= cat.workspaceNames.count)
            ? cat.workspaceNames[idx - 1] : ""
        // Master = first in the WS's tiling order, and only for engines
        // that have a master slot (mirrors `WorkspaceCatalog.snapshot`).
        let mode = cat.mode(of: idx)
        let master = (LayoutRegistry.engine(named: mode)?.hasMaster ?? false)
            && cat.orderedMembers(of: idx).first == id
        // A stashed (off-screen) scratchpad reports no shelf name — only a
        // settled (summoned) one does, matching the snapshot convention.
        let scratchpad = cat.isStashed(id) ? nil : cat.scratchpad(forWindow: id)
        return WindowQueryEntry.FacetWindowState(
            workspace: name,
            workspaceIndex: idx,
            tags: cat.tagModel.names(in: slot.tags),
            floating: cat.isFloating(id),
            sticky: cat.isSticky(id),
            master: master,
            mark: cat.mark(forWindow: id),
            scratchpad: scratchpad)
    }
}
