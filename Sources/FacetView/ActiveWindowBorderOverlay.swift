// ⑤ Active-window border. A borderless, click-through overlay panel
// that rings the currently-focused third-party window with the
// `[border]` style — the same neon/cyber/rainbow effect the facet
// panel wears, reusing BorderFX wholesale.
//
// Buddha-palm constraint: facet never draws inside another app's
// window, so the ring is a transparent panel laid *over* the focused
// window's frame, not pixels poked into it. The Controller feeds it
// the focused window's settled frame on every reconcile and hides it
// while a window is in motion (drag / resize) — by construction this
// sidesteps the chase-the-moving-window jank that retired yabai's
// border feature.
//
// Desktop-local on purpose: the panel uses the DEFAULT collection
// behaviour (no `.canJoinAllSpaces`), so on a mac-desktop switch it
// slides away with its own desktop instead of staying pinned and
// de-compositing into a flicker. The Controller re-places it on the
// destination desktop after the next reconcile. See memory
// [[facet-space-slide-overlay-flicker]].

import AppKit
import FacetCore

@MainActor
public final class ActiveWindowBorderOverlay {
    private let panel: NSPanel
    /// The inset view whose layer carries the border + glow. Held a
    /// `glowPad` margin inside the panel so an outward glow shadow has
    /// room to bloom without the panel's own bounds clipping it.
    private let ring = NSView()
    private let fx = BorderFX()
    /// The window the ring currently tracks (nil = hidden).
    public private(set) var tracked: WindowID?

    /// Margin between the panel edge and the ring, for the glow bloom.
    private let glowPad: CGFloat = 28
    /// Window-corner radius to match macOS's rounded corners.
    private let corner: CGFloat = 10

    public init() {
        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar          // above apps; facet panel is higher
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true   // click-through
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // DEFAULT collection behaviour (desktop-local): no
        // `.canJoinAllSpaces` so the ring rides its own desktop's slide.
        panel.collectionBehavior = [.fullScreenAuxiliary]

        let container = NSView()
        container.wantsLayer = true
        ring.wantsLayer = true
        ring.layer?.cornerRadius = corner
        ring.layer?.cornerCurve = .continuous
        ring.layer?.masksToBounds = false   // let the glow bloom outward
        container.addSubview(ring)
        panel.contentView = container

        fx.onRepaint = { [weak self] in
            guard let self, let l = self.ring.layer else { return }
            self.fx.apply(to: l)
        }
    }

    /// Push the `[border]` style (same args as PanelHost.applyBorder).
    public func configure(effectName: String, glow: Bool, width: CGFloat,
                          cycleSeconds: CGFloat, cycleColors: Bool,
                          minWidth: CGFloat?, maxWidth: CGFloat?) {
        fx.configure(effectName: effectName, glow: glow, width: width,
                     cycleSeconds: cycleSeconds, cycleColors: cycleColors,
                     minWidth: minWidth, maxWidth: maxWidth)
    }

    /// Place (or move) the ring around `frame` (an AppKit, bottom-left
    /// screen rect) for window `id`. Fires the neon flash when `flash`
    /// is set (a focus change). Cheap to call every reconcile: only
    /// re-frames when the rect actually moved.
    public func show(around frame: NSRect, for id: WindowID, flash: Bool) {
        let outer = frame.insetBy(dx: -glowPad, dy: -glowPad)
        if panel.frame != outer {
            panel.setFrame(outer, display: false)
            ring.frame = NSRect(x: glowPad, y: glowPad,
                                width: frame.width, height: frame.height)
            fx.apply(to: ring.layer!)
        }
        if tracked == nil { panel.orderFront(nil) }   // never key: no focus theft
        tracked = id
        if flash { fx.flash() }
    }

    /// Tear the ring down (hidden / no focused window / mid-motion).
    public func hide() {
        guard tracked != nil else { return }
        tracked = nil
        panel.orderOut(nil)
    }
}
