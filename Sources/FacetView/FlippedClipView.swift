// Top-down `NSClipView`.
//
// Used as the documentView's clip in our scroll views so that resize
// (grip drag) anchors content to the *top* rather than the bottom.
// Without this, growing the panel via the grip would leave blank
// space at the top and shove rows toward the bottom edge.
//
// Memory [[grid-branch-grip-intermittent]]: non-flipped NSClipView
// caused an intermittent grip-drag failure in a prior project;
// facet uses flipped from day one.

import AppKit

public final class FlippedClipView: NSClipView {
    public override var isFlipped: Bool { true }
}
