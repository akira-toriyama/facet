// Y-down NSView used as the workspace-drag ghost container so child
// NSImageViews can be positioned with the same cell-local rects the
// RailView (itself flipped) already stores — an unflipped ghost would
// draw the mini-thumbnails upside-down. (Copy of the grid's
// FlippedView; the rail can't import FacetViewGrid.)

import AppKit

public final class FlippedView: NSView {
    public override var isFlipped: Bool { true }
}
