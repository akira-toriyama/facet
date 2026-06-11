// Real-window DnD prediction overlay (枠C PR-3, the 演出).
//
// While the user drags a tiled window, this shows the layout that WILL
// result if they drop right now — HazeOver-style: a dark veil dims the
// whole tiled area, and the windows the drop MOVES are punched back to
// clear so they stand out (spotlit), outlined in the DnD palette. The
// frames come from the backend's `predictedDrop`, which runs the SAME
// swap / insert + tiling math the commit runs, so "what you see is what
// lands" (no drift).
//
// Borderless / nonactivating / click-through panel at `.statusBar` (the
// PreviewOverlay pattern) so it floats above the desktop windows while
// facet stays fully operable. Palette echoes the tree DnD: the dragged
// window (X) gets a solid accent outline, the windows it reshapes get a
// dashed secondary outline.

import AppKit
import FacetCore

@MainActor
public final class DndPredictionOverlay {
    private let panel: NSPanel
    private let view = PredictionView()

    public init() {
        panel = .clickThroughOverlay(hasShadow: false)
        panel.contentView = view
    }

    /// Show the predicted layout. `screen` bounds the dimmed area and
    /// `frames` are the predicted window rects — both AppKit screen
    /// coords (bottom-left origin). `dragged` is the grabbed window;
    /// `affected` are the other windows the drop relocates. Only those
    /// are spotlit (cut out of the veil); everything else is dimmed.
    public func show(screen: NSRect, frames: [WindowID: NSRect],
                     dragged: WindowID, affected: Set<WindowID>) {
        view.origin = screen.origin
        view.frames = frames
        view.dragged = dragged
        view.affected = affected
        panel.setFrame(screen, display: true)
        view.needsDisplay = true
        panel.orderFront(nil)                    // never makeKey
    }

    public func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }
}

private final class PredictionView: NSView {
    var origin: CGPoint = .zero                  // panel/screen origin (AppKit)
    var frames: [WindowID: NSRect] = [:]
    var dragged: WindowID?
    var affected: Set<WindowID> = []

    override var isFlipped: Bool { false }       // AppKit bottom-left

    private func local(_ f: NSRect) -> NSRect {
        NSRect(x: f.minX - origin.x, y: f.minY - origin.y,
               width: f.width, height: f.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        // The windows the drop moves are the spotlight; everything else
        // is dimmed.
        let moving = frames.filter { $0.key == dragged || affected.contains($0.key) }
        guard !moving.isEmpty else { return }

        // 1. Dark veil over the whole area, with the spotlit slots cut
        //    out (even-odd winding turns the inner rects into holes).
        let veil = NSBezierPath(rect: bounds)
        for (_, f) in moving {
            veil.append(NSBezierPath(roundedRect: local(f),
                                     xRadius: 4, yRadius: 4))
        }
        veil.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.5).setFill()
        veil.fill()

        // 2. Outline the spotlit slots — solid accent for the dragged
        //    window, dashed secondary for the windows it reshapes.
        for (id, f) in moving {
            let path = NSBezierPath(roundedRect: local(f),
                                    xRadius: 4, yRadius: 4)
            if id == dragged {
                pal.primary.setStroke(); path.lineWidth = 2
                path.stroke()
            } else {
                pal.secondary.setStroke(); path.lineWidth = 1.5
                path.setLineDash([4, 3], count: 2, phase: 0)
                path.stroke()
            }
        }
    }
}
