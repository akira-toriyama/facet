// Standalone window-rescue scan + move — the AX side of the crash
// path (`facet --rescue`) and the auto-heal sweep. Lives in
// FacetAccessibility next to AXGeom so all AX side-effects stay in
// one module; the geometry decision (`isCornerParked`) is the pure
// FacetCore helper `RescueGeometry`.
//
// "Standalone" matters: after a crash there is no `NativeAdapter`
// (no catalog, no observers) — `facet --rescue` boots nothing, so
// the enumeration can't lean on the adapter's instance method. This
// is a deliberate, self-contained CGWindowList + AX scan.

import AppKit
import ApplicationServices
import CoreGraphics
import FacetCore

public enum AXRescue {

    /// One live window the rescue scan saw: its CGWindowID, owning
    /// pid, and current Quartz-coords frame. Pure data — no AX
    /// element retained.
    public struct Candidate: Sendable {
        public let cgID: CGWindowID
        public let pid: pid_t
        public let frame: CGRect

        public init(cgID: CGWindowID, pid: pid_t, frame: CGRect) {
            self.cgID = cgID
            self.pid = pid
            self.frame = frame
        }
    }

    /// Enumerate layer-0, non-facet windows via CGWindowList for the
    /// standalone rescue. **Mirrors the filtering in
    /// `NativeAdapter.enumerateCGWindows`** (own-pid / layer 0 /
    /// Window Server / borders excluded) — keep the two in sync; the
    /// duplication is justified because no `NativeAdapter` instance
    /// exists pre-server. Returns only what the rescue needs
    /// (`cgID` / `pid` / `frame`), no `Window` model.
    public static func liveCandidates(excludingPID selfPID: pid_t)
        -> [Candidate]
    {
        let opts: CGWindowListOption = [
            .optionAll, .excludeDesktopElements,
        ]
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let myPid = Int(selfPID)
        return raw.compactMap { dict in
            guard
                let cgID = dict[kCGWindowNumber as String] as? CGWindowID,
                let pid = dict[kCGWindowOwnerPID as String] as? Int,
                pid != myPid
            else { return nil }
            let layer = dict[kCGWindowLayer as String] as? Int ?? 0
            if layer != 0 { return nil }
            let owner = dict[kCGWindowOwnerName as String]
                as? String ?? ""
            if owner == "Window Server" || owner == "borders" {
                return nil
            }
            guard
                let b = dict[kCGWindowBounds as String] as? [String: Any]
            else { return nil }
            let frame = CGRect(
                x: b["X"]      as? CGFloat ?? 0,
                y: b["Y"]      as? CGFloat ?? 0,
                width: b["Width"]  as? CGFloat ?? 0,
                height: b["Height"] as? CGFloat ?? 0)
            return Candidate(cgID: cgID, pid: pid_t(pid), frame: frame)
        }
    }

    /// Move every corner-parked candidate back on-screen. For each
    /// candidate whose top-left sits within `band` px of its display's
    /// bottom-right corner (`RescueGeometry.isCornerParked` — the
    /// clamp-aware park signature), resolve its AX element and
    /// `setPosition` it to `target(displayBounds)` (size untouched —
    /// parking never resized it). Returns the count actually moved.
    /// `target` maps a display's bounds rect to the on-screen
    /// destination origin (the caller supplies the visibleFrame-based
    /// rescue target).
    @discardableResult
    public static func rescueCornerParked(
        _ candidates: [Candidate],
        band: CGFloat = RescueGeometry.cornerBand,
        target: (_ displayBounds: CGRect) -> CGPoint
    ) -> Int {
        var moved = 0
        for c in candidates {
            let bounds = Displays.containing(c.frame.origin)
            guard RescueGeometry.isCornerParked(origin: c.frame.origin,
                                                displayBounds: bounds,
                                                band: band)
            else { continue }
            guard let ax = AXGeom.window(for: c.cgID, pid: c.pid)
            else { continue }
            // Cascade multiple rescues so they fan out instead of
            // stacking at the exact same on-screen spot.
            let base = target(bounds)
            let dest = CGPoint(x: base.x + CGFloat(moved) * 32,
                               y: base.y + CGFloat(moved) * 32)
            if AXGeom.setPosition(ax, dest) { moved += 1 }
        }
        return moved
    }
}
