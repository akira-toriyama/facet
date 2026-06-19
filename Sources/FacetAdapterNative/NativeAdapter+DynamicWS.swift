// Dynamic workspace commands (A: runtime WS set) — add / remove /
// rename / reorder / switch, on-screen visibility resync, and the shared
// anchor-park primitive (`applyHide`). The layout-mode, window-DnD, and
// tagging commands that once shared this file now live in
// NativeAdapter+{LayoutMode,WindowDnD,Tagging}.swift (same-module
// extensions, no logic change). Originally extracted from
// NativeAdapter.swift (#182 phase 4).

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import FacetAccessibility
import FacetCore

extension NativeAdapter {
    // MARK: - Dynamic workspace commands (A: runtime WS set)

    public func switchWorkspace(named name: String, autoFocus: Bool) {
        guard config.isMacDesktopManaged(ordinal: activeMacDesktopOrdinal)
        else { return }
        guard let pos = catalog.index(ofName: name) else {
            Log.debug("native: switchWorkspace(named: \"\(name)\") → no match")
            return
        }
        switchWorkspace(toIndex: pos - 1, autoFocus: autoFocus)
    }

    public func addWorkspace() {
        guard config.isMacDesktopManaged(ordinal: activeMacDesktopOrdinal)
        else { return }
        let pos = catalog.addWorkspace()
        // Section-managed desktop: the new slot is auto-named (emoji pool,
        // index-keyed) like the seeded ones — the user can't name a
        // workspace. Otherwise the catalog's default name stands.
        if config.isSectionModelActive(ordinal: activeMacDesktopOrdinal) {
            catalog.renameWorkspace(pos, to: WorkspaceNaming.name(forIndex: pos - 1))
        }
        Log.debug("native: addWorkspace → position \(pos) "
            + "(count=\(catalog.workspaceCount))")
        eventContinuation.yield(.refreshNeeded)
    }

    public func removeWorkspace(at position: Int?) {
        guard config.isMacDesktopManaged(ordinal: activeMacDesktopOrdinal)
        else { return }
        let target = position ?? catalog.activeIndex
        let rect = activeDisplayRect()
        guard catalog.removeWorkspace(target, in: rect) else {
            Log.debug("native: removeWorkspace(\(target)) → rejected "
                + "(invalid, or last workspace)")
            return
        }
        Log.debug("native: removeWorkspace(\(target)) → "
            + "count=\(catalog.workspaceCount) active=\(catalog.activeIndex)")
        // Windows evacuated to a neighbour and positions shifted —
        // re-establish what's visible (only the active WS) and tile.
        resyncVisibleState(rect: rect)
        eventContinuation.yield(.refreshNeeded)
    }

    public func renameWorkspace(at position: Int?, to name: String) {
        guard config.isMacDesktopManaged(ordinal: activeMacDesktopOrdinal)
        else { return }
        let target = position ?? catalog.activeIndex
        catalog.renameWorkspace(target, to: name)
        Log.debug("native: renameWorkspace(\(target)) → \"\(name)\"")
        eventContinuation.yield(.refreshNeeded)
    }

    public func moveActiveWorkspace(to position: Int) {
        guard config.isMacDesktopManaged(ordinal: activeMacDesktopOrdinal)
        else { return }
        // 1-based position; active follows the moved WS. Pure
        // renumber — windows / visibility don't change.
        guard catalog.moveActiveWorkspace(to: position) else {
            Log.debug("native: moveActiveWorkspace(to: \(position)) → no-op")
            return
        }
        Log.debug("native: moveActiveWorkspace → \(position) "
            + "active=\(catalog.activeIndex)")
        eventContinuation.yield(.refreshNeeded)
    }

    /// Force on-screen reality to match the catalog: only the active
    /// workspace's windows visible (rest parked), then tile. Idempotent
    /// — `applyHide` guards already-parked / already-restored windows —
    /// so it's safe after a remove that shuffled windows + positions.
    private func resyncVisibleState(rect: CGRect) {
        let active = catalog.activeIndex
        var toPark: [WindowRef] = []
        var toRestore: [WindowRef] = []
        for (id, slot) in catalog.windowMap {
            // Sticky windows are park-exempt and stay on-screen
            // everywhere — never park or restore them.
            if catalog.isSticky(id) { continue }
            // Stashed scratchpad windows are the opposite: they must
            // STAY parked off-screen regardless of which WS is active —
            // restoring one when its home WS activates would un-hide the
            // shelf. (A settled scratchpad window isn't stashed, so it
            // parks / restores normally as a floating window.)
            if catalog.isStashed(id) { continue }
            let ref = WindowRef(id: id, pid: slot.pid)
            if slot.workspace == active { toRestore.append(ref) }
            else { toPark.append(ref) }
        }
        applyHide(toPark: toPark, toRestore: toRestore)
        applyLayout(workspace: active, rect: rect)
    }

    /// Park / restore two `WindowRef` lists at the anchor sliver.
    /// Centralises the call so callers (workspace switch,
    /// single-window move) don't repeat it.
    func applyHide(toPark: [WindowRef],
                           toRestore: [WindowRef]) {
        for ref in toPark { parkAnchor(ref) }
        for ref in toRestore { restoreAnchor(ref) }
        if !toPark.isEmpty || !toRestore.isEmpty {
            Log.debug("native: anchor "
                + "parked=\(toPark.count) restored=\(toRestore.count)")
        }
    }
}
