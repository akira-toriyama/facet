// Module-level theme state. Set once at app start from `--theme=`,
// read from every view's `draw` and layout code as `pal.text` etc.
// The `pal` symbol is intentionally short — it appears in dozens
// of view-side call sites.

import AppKit

/// Current theme. Configured via `paletteFor("…")` at startup.
@MainActor
public var pal: Palette = .terminal

/// Theme-aware font factory. Picks system / monospaced / rounded
/// according to `pal.font`.
@MainActor
public func uiFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    switch pal.font {
    case .mono:
        return .monospacedSystemFont(ofSize: size, weight: weight)
    case .rounded:
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: d, size: size) ?? base
        }
        return base
    case .system:
        return .systemFont(ofSize: size, weight: weight)
    }
}

/// Compact label for a workspace's layout mode, shown on the small
/// per-WS header badge across tree / grid / rail. The master-edge
/// engines have long canonical names (`master-bottom` is 13 chars)
/// that overflow the narrow rail band, so abbreviate `master-EDGE` to
/// `m-EDGE` (≤ 8 chars — the same budget the old `centered` fit).
/// Display-only: the layout picker, CLI, and config keep the full
/// canonical name. Any non-master mode is returned verbatim.
public func layoutBadgeLabel(_ mode: String) -> String {
    guard mode.hasPrefix("master-") else { return mode }
    return "m-" + String(mode.dropFirst("master-".count))
}

/// Draw a tiny window-mark badge in the top-left corner of a mini
/// thumbnail `rect`: an accent pill with the mark text when it fits,
/// else just an accent dot — so a marked window stays signalled even in
/// the smallest grid / rail cells. Mirrors the tree's mark pill at
/// ~60% scale; shared by grid + rail so the badge reads the same in
/// both (M9-5 #3). Caller draws inside its own cell clip.
@MainActor
public func drawMiniMarkBadge(_ mark: String, in rect: NSRect) {
    guard !mark.isEmpty else { return }
    let pad: CGFloat = 2, pillH: CGFloat = 9
    let attrs: [NSAttributedString.Key: Any] = [
        .font: uiFont(7, .bold), .foregroundColor: pal.accent,
    ]
    let textW = (mark as NSString).size(withAttributes: attrs).width
    let pillW = min(textW + 6, rect.width - pad * 2)
    if pillW >= 8, pillH <= rect.height - pad * 2 {
        let pill = NSRect(x: rect.minX + pad, y: rect.minY + pad,
                          width: pillW, height: pillH)
        let pp = NSBezierPath(roundedRect: pill,
                              xRadius: pillH / 2, yRadius: pillH / 2)
        (pal.bg ?? .black).withAlphaComponent(0.6).setFill(); pp.fill()
        pal.accent.setStroke(); pp.lineWidth = 0.75; pp.stroke()
        let para = NSMutableParagraphStyle()
        para.alignment = .center; para.lineBreakMode = .byTruncatingTail
        var a = attrs; a[.paragraphStyle] = para
        let th = (mark as NSString).size(withAttributes: a).height
        (mark as NSString).draw(
            in: NSRect(x: pill.minX, y: pill.minY + (pillH - th) / 2,
                       width: pillW, height: th), withAttributes: a)
    } else {
        let d: CGFloat = 4
        pal.accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + pad, y: rect.minY + pad,
                                    width: d, height: d)).fill()
    }
}

/// Secondary-tag membership for the tiny grid / rail thumbnails: this
/// window is ALSO in `count` other tags (it's already shown under its
/// primary tag's cell). Surface that as up to 3 small dots in the
/// BOTTOM-left — `accent2`, so they read apart from the top-left accent
/// mark badge — plus a `+` when there are more than 3. Caller draws
/// inside its own cell clip; coords are flipped (maxY = visual bottom).
/// Tree shows the names as `#tag` chips instead; the mini views only
/// have room for dots (M11-3 PR3b).
@MainActor
public func drawMiniTagDots(_ count: Int, in rect: NSRect) {
    guard count > 0, rect.width > 10, rect.height > 10 else { return }
    let r: CGFloat = 1.6, gap: CGFloat = 3, pad: CGFloat = 3
    let shown = min(count, 3)
    pal.accent2.setFill()
    let cy = rect.maxY - pad - r
    var cx = rect.minX + pad + r
    for _ in 0..<shown {
        NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r,
                                    width: r * 2, height: r * 2)).fill()
        cx += r * 2 + gap
    }
    if count > 3 {
        ("+" as NSString).draw(
            in: NSRect(x: cx - r, y: cy - 5, width: 8, height: 10),
            withAttributes: [.font: uiFont(7, .bold),
                             .foregroundColor: pal.accent2])
    }
}
