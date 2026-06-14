// Dynamic workspace commands (A: runtime WS set) — add / remove /
// rename / reorder, layout-mode set + retile / balance / rotate /
// mirror, DnD swap / insert / resize, display-reconfigure handling,
// and window marks. Extracted unchanged from NativeAdapter.swift
// (#182 phase 4) — same-module extension, no logic change.

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

    public func setLayoutMode(workspaceIndex index: Int, mode: String) {
        let target = index + 1
        let rect = activeDisplayRect()
        cancelSlideForRetarget()
        // BSP → Stack migration parks all but the focused window
        // at the anchor sliver. The catalog's setMode discards
        // layoutTrees / stackOrders entries, so we rely on
        // applyStack post-flip to park non-top members. Symmetric
        // for Stack → BSP.
        let oldMode = catalog.mode(of: target)
        let applied = catalog.setMode(workspace: target,
                                      to: mode, in: rect)
        Log.debug("native: setLayoutMode WS \(target) -> \(applied)")
        if target == catalog.activeIndex {
            // 枠 E Phase 2: animate the reflow only between all-visible
            // layouts. stack parks members (windows appear / disappear),
            // which the slide engine doesn't handle yet — instant there.
            let parks = oldMode == "stack" || applied == "stack"
            if config.effectiveAnimationsEnabled, !parks,
               animateRetile(workspace: target, rect: rect) {
                return
            }
            applyLayout(workspace: target, rect: rect)
        }
        eventContinuation.yield(.refreshNeeded)
    }

    /// Phase δ: respond to a display reconfiguration. Fires
    /// from `displayObserver` 0.5 s after the OS settles on a
    /// new layout. Three steps in order:
    ///
    ///   1. Re-apply the active workspace's layout against the
    ///      now-current visible frame. Inactive workspaces are
    ///      not touched (lazy retile invariant —
    ///      `facet-phase-gamma-lessons`).
    ///   2. Rescue anchor-parked windows whose recorded
    ///      `originalPosition` is no longer on any visible
    ///      display: AX setPosition to the bottom-right anchor
    ///      sliver of the nearest surviving display.
    ///   3. (PanelHost handles its own reconfigure response —
    ///      Controller owns its own `DisplayChangeObserver`,
    ///      we don't notify it from here.)
    @MainActor
    func handleDisplayReconfigure() {
        Log.debug("native: handleDisplayReconfigure")

        // Step 1: re-apply layout of the active WS against the
        // freshly-queried display rect.
        applyLayout(workspace: catalog.activeIndex,
                    rect: activeDisplayRect())

        // Step 2: anchor-parked rescue. Walk every parked
        // window's recorded originalPosition; if it no longer
        // sits on any visible display, move it to the nearest
        // surviving display's anchor sliver.
        let displays = NSScreen.screens.map(\.frame)
        let parkedPositions = catalog.anchorParked.compactMap {
            id -> (WindowID, CGPoint)? in
            guard let pos = catalog.originalPositions[id]
            else { return nil }
            return (id, pos)
        }
        let orphanPoints = DisplayGeometry.orphanedPoints(
            among: parkedPositions.map(\.1),
            displays: displays)
        guard !orphanPoints.isEmpty else {
            eventContinuation.yield(.refreshNeeded)
            return
        }
        // Group orphans by id for the AX dispatch.
        var rescued = 0
        for (id, pos) in parkedPositions where orphanPoints.contains(pos) {
            guard let pid = catalog.pid(for: id) else { continue }
            // Rescue rect: the nearest surviving display. Anchor
            // sliver lives at (maxX-1, maxY-1) of that display.
            let probe = CGRect(x: pos.x, y: pos.y,
                               width: 1, height: 1)
            guard let dest = DisplayGeometry.nearestDisplay(
                to: probe, in: displays) else { continue }
            guard let ax = AXGeom.window(
                for: CGWindowID(id.serverID),
                pid: pid_t(pid)) else { continue }
            let anchor = CGPoint(x: dest.maxX - 1,
                                 y: dest.maxY - 1)
            AXGeom.setPosition(ax, anchor)
            rescued += 1
        }
        if rescued > 0 {
            Log.debug("native: reconfig rescued \(rescued) "
                + "anchor-parked window(s)")
        }
        eventContinuation.yield(.refreshNeeded)
    }

    /// `WindowBackend.retileActiveWorkspace` implementation:
    /// recompute + reapply the active workspace's layout. For
    /// BSP this re-tiles the tree; for stack this re-stacks
    /// (top fills, others park). No-op for float mode.
    public func retileActiveWorkspace() {
        let mode = catalog.mode(of: catalog.activeIndex)
        guard mode == "bsp" || mode == "stack"
                || LayoutRegistry.engine(named: mode) != nil else {
            Log.debug("native: retile noop "
                + "(WS \(catalog.activeIndex) is \(mode))")
            return
        }
        cancelSlideForRetarget()
        let rect = activeDisplayRect()
        // 枠 E Phase 2: animate the in-place reflow. animateRetile owns
        // its settle (applyLayout + refresh); fall through to instant
        // when off / reduce-motion / nothing moved.
        if config.effectiveAnimationsEnabled,
           animateRetile(workspace: catalog.activeIndex, rect: rect) {
            return
        }
        applyLayout(workspace: catalog.activeIndex, rect: rect)
        eventContinuation.yield(.refreshNeeded)
    }

    public func balanceActiveWorkspace() {
        // Master knobs are the only per-WS layout state that drifts;
        // bsp split ratios are fixed at 0.5 today. No knob → nothing
        // to reset. Skip the re-tile when already at the baseline.
        guard hasMasterKnob(catalog.activeIndex) else {
            Log.debug("native: balance noop "
                + "(WS \(catalog.activeIndex) has no master knob)")
            return
        }
        guard catalog.resetParams(workspace: catalog.activeIndex) else {
            Log.debug("native: balance noop (already at baseline)")
            return
        }
        reflowActive(rect: activeDisplayRect())
    }

    public func rotateActiveWorkspace(degrees: Int) {
        guard catalog.rotateTree(workspace: catalog.activeIndex,
                                 degrees: degrees) else {
            Log.debug("native: rotate noop "
                + "(WS \(catalog.activeIndex) not bsp / unchanged)")
            return
        }
        reflowActive(rect: activeDisplayRect())
    }

    public func mirrorActiveWorkspace(_ axis: MirrorAxis) {
        let treeAxis: LayoutTree.Axis =
            axis == .horizontal ? .horizontal : .vertical
        guard catalog.mirrorTree(workspace: catalog.activeIndex,
                                 axis: treeAxis) else {
            Log.debug("native: mirror noop "
                + "(WS \(catalog.activeIndex) not bsp / unchanged)")
            return
        }
        reflowActive(rect: activeDisplayRect())
    }

    public func swapWindows(_ a: WindowID, _ b: WindowID) {
        guard catalog.swapWindows(a, b,
                                  workspace: catalog.activeIndex) else {
            Log.debug("native: swap noop "
                + "a=\(a.serverID) b=\(b.serverID)")
            return
        }
        reflowActive(rect: activeDisplayRect())
    }

    public func insertWindow(_ moved: WindowID, beside target: WindowID,
                             edge: InsertEdge) {
        guard catalog.insertWindow(moved, beside: target, edge: edge,
                                   workspace: catalog.activeIndex) else {
            Log.debug("native: insert noop "
                + "moved=\(moved.serverID) target=\(target.serverID)")
            return
        }
        reflowActive(rect: activeDisplayRect())
    }

    public func resizeWindow(_ id: WindowID, to frame: CGRect,
                             reflowDragged: Bool) {
        // Name the display from the dragged window's centre — it's on the
        // active display, and this avoids the focused-window AX probe every
        // live tick.
        let rect = activeDisplayRect(
            probe: CGPoint(x: frame.midX, y: frame.midY))
        let frozen = catalog.applyResize(id, to: frame,
                                         workspace: catalog.activeIndex, in: rect,
                                         innerGap: config.effectiveInnerGap)
        if reflowDragged {
            // Settle (gesture end / one-shot): a full reflow re-applies the
            // new ratio to everyone, snapping the dragged window onto its
            // freshly-computed slot (≈ where the user left it). Run even
            // when no ratio moved so a native resize the layout can't
            // follow (an out-of-scope grid / stack mode, or a window edge
            // dragged against a screen boundary) snaps the window back to
            // its slot rather than being left at its off-layout size.
            reflowActive(rect: rect)
        } else if let frozen {
            // PR-2 live tick: re-tile only the OPPOSITE subtree. Freeze the
            // dragged window AND its same-subtree mates — the OS is still
            // drawing the native resize, and those mates sit off the divider
            // anchored to the dragged window's (excluded) frame, so re-tiling
            // them to their computed slots would open a gap. `cached: true`
            // = the fast path (cached AX elements, no per-tick lookup) so the
            // opposite side tracks the drag instead of lagging a beat behind.
            applyLayout(workspace: catalog.activeIndex, rect: rect,
                        skip: frozen, cached: true)
        } else {
            Log.debug("native: resize noop id=\(id.serverID)")
        }
    }

    public func windowFrame(_ id: WindowID) -> CGRect? {
        // Prefer the window server (CGWindowList): a single-id description
        // is fast and DOESN'T round-trip to the window's app — which
        // matters during a live resize, when the dragged app (Chrome等) is
        // busy and its AX answers slowly, the main per-tick jank source.
        // kCGWindowBounds is top-left global coords, the same Quartz space
        // as the catalog's tile frames. Fall back to AX if the server has
        // no entry (rare). Read off-main (Controller dispatches on cliQueue).
        let cgID = CGWindowID(id.serverID)
        if let info = CGWindowListCreateDescriptionFromArray(
                [cgID] as CFArray) as? [[String: Any]],
           let b = info.first?[kCGWindowBounds as String] as? [String: Any],
           let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
           let w = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat {
            return CGRect(x: x, y: y, width: w, height: h)
        }
        guard let ax = axWin(id: id),
              let pos = AXGeom.position(ax),
              let size = AXGeom.size(ax) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    public func predictedDrop(dragged a: WindowID, target b: WindowID,
                              zone: IntentZone) -> DropPrediction {
        let rect = activeDisplayRect()
        // Pre-drop computed layout (same math as the commit), then apply
        // the drop to a COPY of the catalog (a value type) and recompute.
        // Diffing the two gives the EXACT set of windows the drop moves —
        // no live-position / sub-pixel noise.
        let before = computedTileFrames(catalog, in: rect)
        var copy = catalog
        let ws = copy.activeIndex
        let changed: Bool
        switch zone {
        case .center:
            changed = copy.swapWindows(a, b, workspace: ws)
        case .edge(let edge):
            changed = copy.insertWindow(a, beside: b, edge: edge, workspace: ws)
        }
        guard changed else { return .none }
        let after = computedTileFrames(copy, in: rect)
        let moved = Set(after.keys.filter { after[$0] != before[$0] })
        return DropPrediction(frames: after, moved: moved)
    }

    /// The active workspace's tiled-window frames as the commit would
    /// place them — engine / tree geometry plus the same inner gap
    /// `applyFrames` applies, so a predicted outline lands exactly on the
    /// gapped on-screen window.
    private func computedTileFrames(_ cat: WorkspaceCatalog,
                                    in rect: CGRect) -> [WindowID: CGRect] {
        let ws = cat.activeIndex
        let raw = cat.mode(of: ws) == "bsp"
            ? cat.tiledFrames(for: ws, in: rect)
            : cat.engineFrames(for: ws, in: rect)
        return applyInnerGap(raw, in: rect, gap: config.effectiveInnerGap)
    }

    public func markFocusedWindow(_ name: String) -> Bool {
        guard let id = focusedWindow() else {
            Log.debug("native: mark \"\(name)\" — no focused window")
            return false
        }
        catalog.setMark(name, to: id)
        Log.debug("native: mark \"\(name)\" -> \(id.serverID)")
        eventContinuation.yield(.refreshNeeded)   // repaint the badge
        return true
    }

    public func focusMark(_ name: String) -> Bool {
        guard let id = catalog.window(forMark: name),
              let slot = catalog.windowMap[id] else {
            Log.debug("native: focus-mark \"\(name)\" — unset / gone")
            return false
        }
        // Cross-WS jump: switch first (un-parks + tiles the target WS,
        // suppressing default focus), then assert the marked window —
        // the same two-step the tree-click path uses. Same WS → assert
        // straight away.
        if slot.workspace != catalog.activeIndex {
            switchWorkspace(toIndex: slot.workspace - 1, autoFocus: false)
        }
        guard let win = enumerateCGWindows().first(where: { $0.id == id })
        else {
            Log.debug("native: focus-mark \"\(name)\" — window vanished")
            return false
        }
        Focus.assert(win, backend: self)
        Log.debug("native: focus-mark \"\(name)\" -> \(id.serverID) "
            + "WS \(slot.workspace)")
        return true
    }

    public func unmark(_ name: String) -> Bool {
        guard catalog.removeMark(name) else {
            Log.debug("native: unmark \"\(name)\" — no such mark")
            return false
        }
        Log.debug("native: unmark \"\(name)\"")
        eventContinuation.yield(.refreshNeeded)   // repaint — badge gone
        return true
    }

    // MARK: - Runtime window tagging (#191, tag mode)

    public func addTagToFocusedWindow(_ name: String) -> Bool {
        applyWindowRetag("tag", name) { $0.addTagToWindow($1, name: name) }
    }

    public func removeTagFromFocusedWindow(_ name: String) -> Bool {
        applyWindowRetag("untag", name) { $0.removeTagFromWindow($1, name: name) }
    }

    public func toggleTagOnFocusedWindow(_ name: String) -> Bool {
        applyWindowRetag("toggle-tag", name) {
            $0.toggleTagOnWindow($1, name: name)
        }
    }

    /// Shared body for the three runtime-retag verbs. Guards tag mode +
    /// a managed focused window, runs the catalog mutator, then — like
    /// `setLens`, on a single window — parks / restores it if its lens
    /// visibility flipped and re-tiles the active union, finally
    /// repainting. Returns `false` when there is no managed focused
    /// window or the mutator rejected the name (unknown on `--untag` /
    /// vocabulary full) so the Controller can surface the error.
    private func applyWindowRetag(
        _ verb: String, _ name: String,
        _ mutate: (inout WorkspaceCatalog, WindowID)
            -> WorkspaceCatalog.RetagVisibility?
    ) -> Bool {
        guard config.isMacDesktopManaged(ordinal: activeMacDesktopOrdinal),
              catalog.grouping == .tag else {
            Log.debug("native: \(verb) \"\(name)\" — not tag mode / unmanaged")
            return false
        }
        guard let id = focusedWindow() else {
            Log.debug("native: \(verb) \"\(name)\" — no focused window")
            return false
        }
        guard let vis = mutate(&catalog, id) else {
            Log.debug("native: \(verb) \"\(name)\" — rejected (unknown / full)")
            return false
        }
        cancelSlideForRetarget()
        if vis != .unchanged, let pid = catalog.windowMap[id]?.pid {
            let ref = WindowRef(id: id, pid: pid)
            applyHide(toPark: vis == .park ? [ref] : [],
                      toRestore: vis == .restore ? [ref] : [])
        }
        applyLayout(workspace: catalog.activeIndex, rect: activeDisplayRect())
        Log.debug("native: \(verb) \"\(name)\" -> \(id.serverID) [\(vis)]")
        eventContinuation.yield(.refreshNeeded)
        return true
    }
}
