// Shared drawing helpers for the tree / grid / rail views (grip dots,
// mark badges, tag dots, a themed text line, the layout-mode label).
//
// The theme STATE itself — the module-level `pal` (a PaletteKit
// `ResolvedPalette`) and the `uiFont` factory — lives in sill's
// PaletteKit (plan atelier) and is re-exported via Palette.swift, so the
// helpers below (and every view call site) read `pal.*` (the Phase-V
// Tailwind field names: `foreground` / `muted` / `primary` / …) and
// `uiFont(...)` without a per-file import.

import AppKit
import PaletteKit

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

/// Draw one text line into `rect` with the theme font (`uiFont`).
/// Shared by the grid + rail workspace-header captions, which both
/// drew an identical single attributed line.
@MainActor
public func drawTextLine(_ s: String, font: CGFloat, weight: NSFont.Weight,
                         color: NSColor, para: NSParagraphStyle, in rect: NSRect) {
    (s as NSString).draw(in: rect, withAttributes: [
        .font: uiFont(font, weight),
        .foregroundColor: color,
        .paragraphStyle: para,
    ])
}

/// A 2-column dot grid — the universal "drag handle" affordance at the
/// left of a workspace header (header drag = WS-swap). Height-aware: in
/// a tall rect (≥ 28pt, the 2-line header) it stretches to a vertical
/// strip spanning ±`tallExtent` around the midline; in shorter rects it
/// falls back to the compact 3-row form. `tallExtent` is the only knob
/// the views differ on — grid / rail use 18 (wider cells), the tree 14
/// (the narrow sidebar would crowd the WS-name column). One texture
/// across tree / grid / rail (M9-5 #4).
@MainActor
public func drawGripDots(in r: NSRect, tallExtent: CGFloat,
                         color: NSColor, alpha: CGFloat) {
    let dotR: CGFloat = 1.15
    let xs = [r.minX + dotR + 1, r.minX + dotR + 5]
    let ys: [CGFloat] = r.height >= 28
        ? stride(from: -tallExtent, through: tallExtent, by: 4.0)
            .map { r.midY + $0 }
        : [r.midY - 4, r.midY, r.midY + 4]
    color.withAlphaComponent(alpha).setFill()
    for x in xs {
        for y in ys {
            NSBezierPath(ovalIn: NSRect(x: x - dotR, y: y - dotR,
                                        width: dotR * 2,
                                        height: dotR * 2)).fill()
        }
    }
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
        .font: uiFont(7, .bold), .foregroundColor: pal.primary,
    ]
    let textW = (mark as NSString).size(withAttributes: attrs).width
    let pillW = min(textW + 6, rect.width - pad * 2)
    if pillW >= 8, pillH <= rect.height - pad * 2 {
        let pill = NSRect(x: rect.minX + pad, y: rect.minY + pad,
                          width: pillW, height: pillH)
        let pp = NSBezierPath(roundedRect: pill,
                              xRadius: pillH / 2, yRadius: pillH / 2)
        (pal.background ?? .black).withAlphaComponent(0.6).setFill(); pp.fill()
        pal.primary.setStroke(); pp.lineWidth = 0.75; pp.stroke()
        let para = NSMutableParagraphStyle()
        para.alignment = .center; para.lineBreakMode = .byTruncatingTail
        var a = attrs; a[.paragraphStyle] = para
        let th = (mark as NSString).size(withAttributes: a).height
        (mark as NSString).draw(
            in: NSRect(x: pill.minX, y: pill.minY + (pillH - th) / 2,
                       width: pillW, height: th), withAttributes: a)
    } else {
        let d: CGFloat = 4
        pal.primary.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + pad, y: rect.minY + pad,
                                    width: d, height: d)).fill()
    }
}

/// Secondary-tag membership for the tiny grid / rail thumbnails: this
/// window is ALSO in `count` other tags (it's already shown under its
/// primary tag's cell). Surface that as up to 3 small dots in the
/// BOTTOM-left — `secondary`, so they read apart from the top-left accent
/// mark badge — plus a `+` when there are more than 3. Caller draws
/// inside its own cell clip; coords are flipped (maxY = visual bottom).
/// Tree shows the names as `#tag` chips instead; the mini views only
/// have room for dots (M11-3 PR3b).
@MainActor
public func drawMiniTagDots(_ count: Int, in rect: NSRect) {
    guard count > 0, rect.width > 10, rect.height > 10 else { return }
    let r: CGFloat = 1.6, gap: CGFloat = 3, pad: CGFloat = 3
    let shown = min(count, 3)
    pal.secondary.setFill()
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
                             .foregroundColor: pal.secondary])
    }
}
