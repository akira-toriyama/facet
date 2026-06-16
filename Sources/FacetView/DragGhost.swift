// Shared drag-ghost CONSTRUCTION for the grid + rail full-screen
// overviews. The lifted window thumb and the floating workspace cell
// look identical in both views, so the view building lives here once,
// parameterized by each view's tunables (`DragGhostStyle`).
//
// Strictly construction-only: the commit / cancel lifecycles (grid's
// FLIP reorder tweens, rail's ack-deadline poll) genuinely differ and
// stay module-local — as does the drag-state invariant that `drag`
// clears on the backend round-trip ack inside `layoutCells`, NOT on
// mouseUp (memory grid-drag-state-lifecycle). Callers keep their thin
// install wrappers: map their own `Cell` fields into these args, add
// the ghost as a subview, set `dragGhost`, call `liftShadow`.

import AppKit
import CoreGraphics

/// Per-view ghost tunables — each overview passes its own values, so
/// sharing the construction can't drift either view's look.
public struct DragGhostStyle: Sendable {
    public let liftScale: CGFloat         // window ghost grows by this on lift
    public let shadowRadius: CGFloat
    public let shadowOpacity: Float
    public let liftDuration: TimeInterval // shadow fade-in
    public let cellCornerRadius: CGFloat  // workspace ghost corner shape
    public let ghostLabelSize: CGFloat    // centred label on an empty-WS ghost

    public init(liftScale: CGFloat,
                shadowRadius: CGFloat,
                shadowOpacity: Float,
                liftDuration: TimeInterval,
                cellCornerRadius: CGFloat,
                ghostLabelSize: CGFloat) {
        self.liftScale = liftScale
        self.shadowRadius = shadowRadius
        self.shadowOpacity = shadowOpacity
        self.liftDuration = liftDuration
        self.cellCornerRadius = cellCornerRadius
        self.ghostLabelSize = ghostLabelSize
    }

    /// Shared "lift" feedback for the grid / rail overview ghosts
    /// (dnd-kit style: ghost grows 1.06× and a soft shadow fades in over
    /// 0.14s). The two overviews differ ONLY in cell corner radius + the
    /// empty-WS ghost label size, so they pass just those — the lift
    /// values were duplicated identically across both Tunables files.
    public static func overview(cellCornerRadius: CGFloat,
                                ghostLabelSize: CGFloat) -> DragGhostStyle {
        DragGhostStyle(liftScale: 1.06, shadowRadius: 14, shadowOpacity: 0.45,
                       liftDuration: 0.14, cellCornerRadius: cellCornerRadius,
                       ghostLabelSize: ghostLabelSize)
    }
}

/// Content of one mini-thumbnail inside a workspace ghost. Mapped
/// caller-side so each view keeps its own fallback policy: grid falls
/// back to the app icon (then blank), rail is captures-only and shows
/// a plain placeholder fill instead.
public enum MiniThumbContent {
    case capture(NSImage)   // cached ScreenCaptureKit thumbnail
    case icon(NSImage)      // app-icon fallback (grid)
    case placeholder        // plain fill (rail; capture not cached yet)
    case blank              // nothing (grid; no icon available either)
}

/// One mini-thumbnail in a workspace ghost: ghost-local rect + content.
public struct MiniThumbSpec {
    public let rect: CGRect
    public let content: MiniThumbContent

    public init(rect: CGRect, content: MiniThumbContent) {
        self.rect = rect
        self.content = content
    }
}

/// Thumb-sized accent ghost for a window drag. Built already at
/// "lifted" size so cursor-follow can start on frame 1 with no pause —
/// the only animation is the shadow softly fading in (`liftShadow`).
/// Going instant on size + animated only on shadow gives smooth feel
/// without the "ガクッ" of a size tween being yanked by mouseDragged
/// origin writes.
///
/// Shows the same captured thumbnail the source cell was showing (so
/// the drag *looks* like the thumb lifted off the cell); otherwise an
/// accent tile with `iconFallback()`'s app icon centred in it. The
/// closure is only evaluated when no thumbnail is cached — rail passes
/// `{ nil }` (captures-only) and lifts a plain accent tile.
@MainActor
public func makeWindowGhost(over rect: CGRect,
                            thumbnail: NSImage?,
                            iconFallback: () -> NSImage?,
                            style: DragGhostStyle,
                            pal: ResolvedPalette) -> NSView {
    let lifted = CGRect(
        x: rect.midX - (rect.width  * style.liftScale) / 2,
        y: rect.midY - (rect.height * style.liftScale) / 2,
        width:  rect.width  * style.liftScale,
        height: rect.height * style.liftScale)
    let g = NSView(frame: lifted)
    g.wantsLayer = true
    g.layer?.cornerRadius = 4
    g.layer?.cornerCurve = .continuous
    g.layer?.masksToBounds = true
    g.layer?.borderColor = pal.primary.cgColor
    g.layer?.borderWidth = 1.5
    g.layer?.shadowColor = NSColor.black.cgColor
    g.layer?.shadowOffset = CGSize(width: 0, height: -4)
    g.layer?.shadowRadius = style.shadowRadius
    g.layer?.shadowOpacity = 0
    if let img = thumbnail {
        g.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(0.15).cgColor
        let iv = NSImageView(frame: g.bounds)
        iv.image = img
        iv.imageScaling = .scaleAxesIndependently
        iv.imageAlignment = .alignCenter
        iv.autoresizingMask = [.width, .height]
        g.addSubview(iv)
    } else {
        g.layer?.backgroundColor = pal.primary
            .withAlphaComponent(0.45).cgColor
        if let icon = iconFallback() {
            let side = max(16, min(min(lifted.width,
                                       lifted.height) - 8, 48))
            let iv = NSImageView(frame: CGRect(
                x: (lifted.width  - side) / 2,
                y: (lifted.height - side) / 2,
                width: side, height: side))
            iv.image = icon
            iv.imageScaling = .scaleProportionallyDown
            g.addSubview(iv)
        }
    }
    return g
}

/// Cell-sized ghost for a workspace swap. Reproduces the source cell's
/// contents (mini-thumbnails laid out in their backend positions) so
/// the gesture feels like "the whole cell is floating with the cursor"
/// — visually distinct from the thumb-sized accent ghost of a window
/// drag. An empty cell gets its centred WS label instead.
@MainActor
public func makeWorkspaceGhost(cellRect: CGRect,
                               label: String,
                               thumbs: [MiniThumbSpec],
                               style: DragGhostStyle,
                               pal: ResolvedPalette) -> NSView {
    let g = FlippedView(frame: cellRect)
    g.wantsLayer = true
    g.layer?.cornerRadius = style.cellCornerRadius
    g.layer?.cornerCurve = .continuous
    g.layer?.masksToBounds = true
    g.layer?.borderColor = pal.foreground.withAlphaComponent(0.85).cgColor
    g.layer?.borderWidth = 2
    g.layer?.backgroundColor = pal.foreground
        .withAlphaComponent(0.10).cgColor
    g.layer?.shadowColor = NSColor.black.cgColor
    g.layer?.shadowOffset = CGSize(width: 0, height: -4)
    g.layer?.shadowRadius = style.shadowRadius
    g.layer?.shadowOpacity = 0

    if thumbs.isEmpty {
        let label = NSTextField(labelWithString: label)
        label.font = uiFont(style.ghostLabelSize, .bold)
        label.textColor = pal.foreground.withAlphaComponent(0.95)
        label.alignment = .center
        label.sizeToFit()
        label.frame = CGRect(
            x: (g.bounds.width  - label.frame.width)  / 2,
            y: (g.bounds.height - label.frame.height) / 2,
            width: label.frame.width,
            height: label.frame.height)
        label.autoresizingMask =
            [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        g.addSubview(label)
    } else {
        for thumb in thumbs {
            let iv = NSImageView(frame: thumb.rect)
            iv.wantsLayer = true
            iv.layer?.cornerRadius = 3
            iv.layer?.masksToBounds = true
            switch thumb.content {
            case .capture(let img):
                iv.image = img
                iv.imageScaling = .scaleAxesIndependently
            case .icon(let icon):
                iv.image = icon
                iv.imageScaling = .scaleProportionallyDown
                iv.layer?.backgroundColor = pal.foreground
                    .withAlphaComponent(0.22).cgColor
            case .placeholder:
                iv.layer?.backgroundColor = pal.foreground
                    .withAlphaComponent(0.22).cgColor
            case .blank:
                break
            }
            g.addSubview(iv)
        }
    }
    return g
}

/// Fade the lifted ghost's drop shadow in over `style.liftDuration`
/// (shared by the window + workspace ghosts of both overviews).
@MainActor
public func liftShadow(_ ghost: NSView, style: DragGhostStyle) {
    let fade = CABasicAnimation(keyPath: "shadowOpacity")
    fade.fromValue = 0
    fade.toValue = style.shadowOpacity
    fade.duration = style.liftDuration
    fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
    ghost.layer?.shadowOpacity = style.shadowOpacity
    ghost.layer?.add(fade, forKey: "shadow-lift")
}

/// Centre the ghost on the cursor (both views' cursor-follow).
@MainActor
public func positionGhost(_ ghost: NSView?, at p: CGPoint) {
    guard let g = ghost else { return }
    g.frame.origin = CGPoint(x: p.x - g.frame.width / 2,
                             y: p.y - g.frame.height / 2)
}
