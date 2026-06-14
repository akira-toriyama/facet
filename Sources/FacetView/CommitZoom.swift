// A "zoom a captured cell up to fill the view, then commit" transition,
// shared by the full-screen overviews (`--view grid` / `--view rail`).
//
// When the user commits a workspace switch (Return on the focal cell),
// the overview captures that cell's current rendering and hands it here.
// The image then eases from the cell's rect out to fill the whole view
// ("entering" that workspace); when the ease finishes the supplied
// `perform` closure runs the actual switch + close. The owning view:
//   • calls `draw(in:)` first thing in its own `draw` — if it returns
//     true, the view early-returns (only the zoom shows during it);
//   • gates input on `isActive`;
//   • calls `finish()` if it closes mid-zoom, so the pending switch
//     still fires.
// The caller decides *whether* to animate (e.g. it skips this and runs
// `perform` directly under Reduce Motion).

import AppKit

public extension NSView {
    /// Capture a region of the view's current rendering as an image
    /// (used to seed a `CommitZoom` and the rail's browse crossfade).
    /// `nil` for a degenerate rect.
    func snapshotRegion(_ rect: NSRect) -> NSImage? {
        guard rect.width > 1, rect.height > 1,
              let rep = bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        cacheDisplay(in: rect, to: rep)
        let img = NSImage(size: rect.size)
        img.addRepresentation(rep)
        return img
    }
}

@MainActor
public final class CommitZoom {
    public private(set) var isActive = false
    private var image: NSImage?
    private var from: NSRect = .zero
    private var start: Date?
    private var timer: Timer?
    private var perform: (() -> Void)?
    private var redraw: (() -> Void)?
    private let duration: TimeInterval

    public init(duration: TimeInterval) { self.duration = duration }

    /// Begin the zoom from `from` (the focal cell's rect). `redraw` is
    /// invoked every frame; `perform` (the switch + close) fires when the
    /// ease completes. A no-op if a zoom is already running.
    public func begin(image: NSImage, from: NSRect,
                      redraw: @escaping () -> Void,
                      perform: @escaping () -> Void) {
        guard !isActive else { return }
        isActive = true
        self.image = image; self.from = from
        self.redraw = redraw; self.perform = perform
        start = Date()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)   // fire during key-mash too
        timer = t
        redraw()
    }

    /// Draw the in-flight zoom into `bounds`; returns `true` if it drew
    /// (the caller should then early-return from its own `draw`).
    public func draw(in bounds: NSRect) -> Bool {
        guard isActive, let img = image, let s = start else { return false }
        let t = min(1, CGFloat(Date().timeIntervalSince(s) / duration))
        let e = 1 - pow(1 - t, 3)   // ease-out cubic
        let r = NSRect(x: from.minX + (bounds.minX - from.minX) * e,
                       y: from.minY + (bounds.minY - from.minY) * e,
                       width: from.width + (bounds.width - from.width) * e,
                       height: from.height + (bounds.height - from.height) * e)
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
        return true
    }

    private func tick() {
        guard isActive, let s = start else { finish(); return }
        if Date().timeIntervalSince(s) / duration >= 1 { finish() }
        else { redraw?() }
    }

    /// Finish now (ease complete, or the overview closed mid-zoom): fire
    /// the pending switch exactly once.
    public func finish() {
        timer?.invalidate(); timer = nil; start = nil
        isActive = false
        let p = perform
        perform = nil; image = nil; redraw = nil
        p?()
    }
}
