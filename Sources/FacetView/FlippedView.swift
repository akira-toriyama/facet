// Y-down (top-left origin) `NSView`.
//
// Used as the workspace-drag ghost container in the grid and rail
// overviews so child `NSImageView`s can be positioned with the same
// cell-local rects the (already-flipped) overview stores — an
// unflipped ghost would draw the mini-thumbnails upside-down and at
// the wrong Y. Sibling of `FlippedClipView`; hoisted into FacetView so
// Grid and Rail share one definition instead of a per-module copy.

import AppKit

public final class FlippedView: NSView {
    public override var isFlipped: Bool { true }
}
