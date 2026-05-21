// Manages a pool of `PreviewOverlay` panels so we can show all the
// windows of a workspace at once (when hovering / keyboard-selecting
// a workspace header). Panels are reused across shows; never
// destroyed — the cost is paid once, on first need.

import AppKit
import FacetCore

@MainActor
public final class PreviewOverlayPool {
    private var all: [PreviewOverlay] = []
    private var inUse: [WindowID: PreviewOverlay] = [:]

    public init() {}

    public var inUseWindows: Set<WindowID> { Set(inUse.keys) }

    /// Show / update a single window's overlay.
    public func show(_ id: WindowID, img: NSImage, frame: CGRect) {
        if let o = inUse[id] {
            o.show(img, at: frame, for: id); return
        }
        let o: PreviewOverlay
        if let free = all.first(where: { ov in
            !inUse.values.contains(where: { $0 === ov })
        }) {
            o = free
        } else {
            o = PreviewOverlay(); all.append(o)
        }
        inUse[id] = o
        o.show(img, at: frame, for: id)
    }

    /// Hide overlays whose window id is not in the target set
    /// (used when the hovered / selected workspace changes — drop
    /// the stale ones, keep the rest visible).
    public func setActiveWindows(_ ids: Set<WindowID>) {
        for (id, o) in inUse where !ids.contains(id) {
            o.hide(); inUse.removeValue(forKey: id)
        }
    }

    public func hideAll() {
        for (_, o) in inUse { o.hide() }
        inUse.removeAll()
    }
}
