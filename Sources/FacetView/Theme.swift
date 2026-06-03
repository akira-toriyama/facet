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
