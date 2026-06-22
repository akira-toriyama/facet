// `facet query --windows` synthesis (#223), split across two phases:
//
//   • `queryFacetStates()` — reads the catalog structs (active + parked)
//     into an immutable `[WindowID: FacetWindowState]` map. P6: the catalog
//     is cliQueue-confined, so this read runs on `cliQueue` — `Controller`'s
//     `writeQuery` calls it inside `cliQueue.async` (it used to read on
//     main, which raced once the command mutators moved off main). It
//     touches none of the heavy OS APIs and is the only `parkedCatalogs`
//     read in the codebase.
//
//   • `queryEntries(facetStates:)` — the heavy, catalog-FREE sweep:
//     `enumerateCGWindows()` (CGWindowList .optionAll → every real window
//     on every space), `MacDesktops.ordinalMap()` + `ids(forWindow:)` for
//     the desktop ordinal (`nil` when SkyLight is down / unresolvable),
//     and `AXTitles.resolve` for on-screen windows missing a title
//     (off-screen → "", to bound AX traffic). Runs on the same `cliQueue`
//     pass (AXTitles is cliQueue-only by contract); merges the passed-in
//     facet map by window id.
//
//   • `definedTagNames()` — a cheap active-catalog read for `facet query
//     --tags` (#228). Production callers invoke it on `cliQueue` (like every
//     catalog read), but — unlike the two phases above — it carries NO
//     `dispatchPrecondition`: it's directly unit-tested off-queue.
//
// Both phases on the one cliQueue serialization point: the catalog read
// never races the cliQueue mutators, and the heavy sweep stays off main.
// Read-only / SIP-on throughout.

import AppKit
import FacetCore
import FacetAccessibility

extension NativeAdapter {

    /// All tags currently applied to any managed window — the de-facto tag
    /// vocabulary (`facet query --tags`, #228). The union of every live
    /// window's free-form tag set (no vocabulary registry exists post-EX-4),
    /// sorted. A cheap catalog read; P6 → callers invoke it on `cliQueue`
    /// (`writeStatus`) like every other catalog read.
    public func definedTagNames() -> [String] {
        Array(Set(catalog.windowMap.values.flatMap { $0.tags })).sorted()
    }

    public func queryFacetStates()
        -> [WindowID: WindowQueryEntry.FacetWindowState]
    {
        // P6: the only place `parkedCatalogs` is read. `writeQuery` now
        // calls this on cliQueue (it used to read on main) — fail fast if
        // a caller regresses.
        dispatchPrecondition(condition: .onQueue(cliQueue))
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
                                          isActive: true,
                                          layoutMode: StatefulMode.float,
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
    ///
    /// Internal (not `private`) so the projection-parity tests can assert
    /// it agrees with `snapshot` per window (the pivot makes
    /// this the single window-centric source — Prep-1/cov-01). Call it
    /// directly off-queue; the public `queryFacetStates()` traps off the
    /// cliQueue via `dispatchPrecondition`, this helper does not.
    func facetState(forWindow id: WindowID, in cat: WorkspaceCatalog)
        -> WindowQueryEntry.FacetWindowState?
    {
        guard let slot = cat.windowMap[id] else { return nil }
        // A stashed (off-screen) scratchpad reports no shelf name — only a
        // settled (summoned) one does, matching the snapshot convention.
        let scratchpad = cat.isStashed(id) ? nil : cat.scratchpad(forWindow: id)
        // orphan (workspace == nil): no home WS — report "迷子" + index 0 (0 is
        // not a valid 1-based index, the orphan sentinel) and no master/mode
        // lookup (an orphan is in no layout). It is still reported (distinct),
        // never silently dropped from `facet query`.
        guard let ws = slot.workspace else {
            return WindowQueryEntry.FacetWindowState(
                workspace: "迷子",
                workspaceIndex: 0,
                tags: slot.tags.sorted(),
                floating: cat.isFloating(id),
                sticky: cat.isSticky(id),
                master: false,
                mark: cat.mark(forWindow: id),
                scratchpad: scratchpad)
        }
        let name = (ws >= 1 && ws <= cat.workspaceNames.count)
            ? cat.workspaceNames[ws - 1] : ""
        // Master = first in the WS's tiling order, and only for engines
        // that have a master slot (mirrors `WorkspaceCatalog.snapshot`).
        let mode = cat.mode(of: ws)
        let master = (LayoutRegistry.engine(named: mode)?.hasMaster ?? false)
            && cat.orderedMembers(of: ws).first == id
        return WindowQueryEntry.FacetWindowState(
            workspace: name,
            workspaceIndex: ws,
            tags: slot.tags.sorted(),
            floating: cat.isFloating(id),
            sticky: cat.isSticky(id),
            master: master,
            mark: cat.mark(forWindow: id),
            scratchpad: scratchpad)
    }
}
