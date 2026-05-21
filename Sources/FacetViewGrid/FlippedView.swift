// Y-down ``NSView`` used as the workspace-drag ghost container so
// child ``NSImageView``s can be positioned with the same
// cell-local rects ``GridView.WindowHit.rect`` already stores —
// GridView itself is flipped, so an unflipped ghost would draw
// thumbnails upside-down and at the wrong Y.

import AppKit

public final class FlippedView: NSView {
    public override var isFlipped: Bool { true }
}
