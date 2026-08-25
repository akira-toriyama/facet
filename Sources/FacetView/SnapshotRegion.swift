// The overview surfaces' snapshot hook: capture a region of a view's
// current rendering as an image. Seeds the SwiftUI commit zoom (the
// "cell zooms out to fill the screen" switch transition, grid + rail)
// and the rail's browse crossfade.

import AppKit

public extension NSView {
    /// Capture a region of the view's current rendering as an image.
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
