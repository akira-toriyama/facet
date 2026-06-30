// Anchor hide / show (AX side-effects) — park a window to the 1×41px
// bottom-right sliver and restore it (memory:
// native-window-hide-methods). Extracted unchanged from
// NativeAdapter.swift (#182 phase 4) — same-module extension, no
// logic change.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import FacetAccessibility
import FacetCore

extension NativeAdapter {
    // MARK: - Anchor hide / show (AX side-effects)

    /// Move the window to a 1×41 px sliver in the bottom-right
    /// corner of the display it currently sits on. macOS's clamp
    /// guarantees 41 px of title-bar stays on-screen (memory:
    /// native-window-hide-methods), so we can't fully hide via
    /// public APIs — anchor minimises the visible footprint while
    /// keeping the window recoverable from Mission Control if
    /// facet crashes (memory: facet-buddha-palm-principle).
    func parkAnchor(_ ref: WindowRef) {
        guard catalog.shouldParkAnchor(ref.id) else { return }
        guard
            let ax = AXGeom.window(for: CGWindowID(ref.id.serverID),
                                   pid: pid_t(ref.pid)),
            let pos = AXGeom.position(ax),
            let size = AXGeom.size(ax)
        else { return }
        let center = CGPoint(x: pos.x + size.width / 2,
                             y: pos.y + size.height / 2)
        let hidden = Displays.anchorSliver(near: center)
        AXGeom.setPosition(ax, hidden)
        catalog.markAnchorParked(ref.id, originalPosition: pos)
    }

    /// Reverse of `parkAnchor`: place the window back at its
    /// pre-park position. No-ops when the window isn't currently
    /// parked (defensive against double-restore on rapid switch).
    func restoreAnchor(_ ref: WindowRef) {
        guard let orig = catalog.consumeAnchorRestore(ref.id) else { return }
        guard let ax = AXGeom.window(
                for: CGWindowID(ref.id.serverID), pid: pid_t(ref.pid))
        else { return }
        AXGeom.setPosition(ax, orig)
    }

    /// `WindowBackend.restoreAllParked` — the graceful-quit rescue
    /// (mechanism ①). Move every anchor-parked window in EVERY
    /// per-mac-desktop catalog back to its EXACT recorded pre-park
    /// origin, so a clean exit (`--quit` / Cmd+Q) leaves no window
    /// stranded in the corner.
    ///
    /// **Must be called on `cliQueue`** (the catalog serialization
    /// point) — the Controller's graceful-shutdown wraps it in
    /// `cliQueue.async` so it can't race a poll-reconcile, while the
    /// main run loop stays free (so an in-flight refresh's
    /// `activeDisplayRect` main-hop can still complete and nothing
    /// deadlocks — window-rescue plan R2). Reads ONLY recorded origins,
    /// never NSScreen / `visibleFrame`. Only the active desktop's
    /// windows actually move (public AX is Space-scoped); off-desktop
    /// writes silently no-op — mechanism ② (auto-heal on desktop
    /// switch) and `facet --rescue` cover those.
    public func restoreAllParked() {
        dispatchPrecondition(condition: .onQueue(cliQueue))
        var catalogs = Array(parkedCatalogs.values)
        catalogs.append(catalog)
        var restored = 0
        for cat in catalogs {
            for id in cat.anchorParked {
                guard
                    let orig = cat.originalPositions[id],
                    let pid = cat.pid(for: id),
                    let ax = AXGeom.window(
                        for: CGWindowID(id.serverID), pid: pid_t(pid))
                else { continue }
                if AXGeom.setPosition(ax, orig) { restored += 1 }
            }
        }
        Log.debug("native: restoreAllParked moved \(restored) window(s)")
    }

    // AX helpers (window lookup, position / size, display match)
    // live in FacetAccessibility.AXGeom / .Displays.
}
