// Real-window drag-and-drop + resize (枠 C) — swap / insert / live
// resize, window-frame query, and drop prediction. Extracted unchanged
// from NativeAdapter+DynamicWS.swift — same-module extension, no logic
// change.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import FacetAccessibility
import FacetCore

extension NativeAdapter {
    public func swapWindows(_ a: WindowID, _ b: WindowID) {
        dispatchPrecondition(condition: .onQueue(cliQueue))   // P6
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
        dispatchPrecondition(condition: .onQueue(cliQueue))   // P6
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
        dispatchPrecondition(condition: .onQueue(cliQueue))   // P6
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
        dispatchPrecondition(condition: .onQueue(cliQueue))   // P6
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
        let raw = cat.mode(of: ws) == StatefulMode.bsp
            ? cat.tiledFrames(for: ws, in: rect)
            : cat.engineFrames(for: ws, in: rect)
        return applyInnerGap(raw, in: rect, gap: config.effectiveInnerGap)
    }
}
