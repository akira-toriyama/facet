// An NSScroller that paints its knob in the active palette (`pal`)
// instead of the system grey, while keeping the macOS overlay style +
// auto-fade. The tree panel's scroll view uses one per axis so the
// scrollbars match the theme rather than reading as a generic system
// chrome bolted onto the themed panel.

import AppKit

@MainActor
public final class ThemedScroller: NSScroller {
    // Required so the scroll view still treats us as an overlay scroller
    // (thin, floating, auto-fading) rather than falling back to the
    // legacy gutter style.
    public override class var isCompatibleWithOverlayScrollers: Bool { true }

    /// Per-surface palette (PR-B). Wired by PanelHost to the tree box —
    /// the scroll knob follows the tree theme's foreground.
    public var paletteBox: PaletteBox!
    private var pal: ResolvedPalette { paletteBox.pal }

    public override func drawKnob() {
        let r = rect(for: .knob)
        guard r.width > 1, r.height > 1 else { return }
        // Pill: inset on the thin axis so the knob floats with a little
        // breathing room; full radius for rounded ends.
        let horizontal = r.width > r.height
        let k = r.insetBy(dx: horizontal ? 0 : 2, dy: horizontal ? 2 : 0)
        let radius = min(k.width, k.height) / 2
        // Follows the theme's foreground; the system still modulates our
        // alphaValue for the overlay fade, so this multiplies into it.
        pal.foreground.withAlphaComponent(0.40).setFill()
        NSBezierPath(roundedRect: k, xRadius: radius, yRadius: radius).fill()
    }

    public override func drawKnobSlot(in slotRect: NSRect, highlight: Bool) {
        // Transparent track — keep the overlay look (the knob floats over
        // the content; no grey gutter).
    }
}
