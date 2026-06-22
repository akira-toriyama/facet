// Layout-mode commands — set layout mode + retile / balance / rotate /
// mirror, plus the Phase δ display-reconfigure response. Extracted
// unchanged from NativeAdapter+DynamicWS.swift — same-module extension,
// no logic change.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import FacetAccessibility
import FacetCore

extension NativeAdapter {
    public func setLayoutMode(workspaceIndex index: Int, mode: String) {
        dispatchPrecondition(condition: .onQueue(cliQueue))   // P6
        let target = index + 1
        let rect = activeDisplayRect()
        // EX-0.3: Section-lens union branch. When a `type="lens"` section is
        // active, --layout must target the LENS UNION, not the underlying
        // active workspace (which tiles no windows on its own while the lens
        // is active). `index` is ignored — the union spans all workspaces.
        if catalog.activeSectionLens != nil {
            // Stateful engines (bsp / stack) thread a per-WS tree and can't
            // represent a cross-workspace union — reject loudly, mirroring
            // the CLI's incompatible-layout check. Use `LensLayout.isStateless`
            // (public, canonical predicate).
            guard LensLayout.isStateless(mode) else {
                errorContinuation.yield(
                    "layout \(mode): not available while a lens is active "
                    + "(bsp / stack are workspace-only)")
                return
            }
            catalog.activeSectionLensLayout = mode.lowercased()
            Log.debug("native: setLayoutMode section-lens-union -> "
                + "\(catalog.activeSectionLensLayout ?? "")")
            applyLayout(workspace: catalog.activeIndex, rect: rect)
            eventContinuation.yield(.refreshNeeded)
            return
        }
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
            let parks = oldMode == StatefulMode.stack || applied == StatefulMode.stack
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
        // P6: NSScreen is main-only, so read the display frames HERE (a
        // value snapshot), then do ALL catalog work + AX on `cliQueue` —
        // the single catalog serialization point. The fired-on-main
        // observer must not touch the catalog directly.
        let displays = NSScreen.screens.map(\.frame)
        cliQueue.async { [weak self] in
            guard let self else { return }

            // Step 1: re-apply layout of the active WS against the
            // freshly-queried display rect (activeDisplayRect hops to main
            // for the visible frame — safe, main is free).
            self.applyLayout(workspace: self.catalog.activeIndex,
                             rect: self.activeDisplayRect())

            // Step 2: anchor-parked rescue. Walk every parked window's
            // recorded originalPosition; if it no longer sits on any
            // visible display, move it to the nearest surviving display's
            // anchor sliver.
            let parkedPositions = self.catalog.anchorParked.compactMap {
                id -> (WindowID, CGPoint)? in
                guard let pos = self.catalog.originalPositions[id]
                else { return nil }
                return (id, pos)
            }
            let orphanPoints = DisplayGeometry.orphanedPoints(
                among: parkedPositions.map(\.1),
                displays: displays)
            guard !orphanPoints.isEmpty else {
                self.eventContinuation.yield(.refreshNeeded)
                return
            }
            // Group orphans by id for the AX dispatch.
            var rescued = 0
            for (id, pos) in parkedPositions where orphanPoints.contains(pos) {
                guard let pid = self.catalog.pid(for: id) else { continue }
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
            self.eventContinuation.yield(.refreshNeeded)
        }
    }

    /// `WindowBackend.retileActiveWorkspace` implementation:
    /// recompute + reapply the active workspace's layout. For
    /// BSP this re-tiles the tree; for stack this re-stacks
    /// (top fills, others park). No-op for float mode.
    public func retileActiveWorkspace() {
        let mode = catalog.mode(of: catalog.activeIndex)
        guard mode == StatefulMode.bsp || mode == StatefulMode.stack
                || LayoutRegistry.engine(named: mode) != nil else {
            Log.debug("native: retile noop "
                + "(WS \(catalog.activeIndex) is \(mode))")
            return
        }
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
}
