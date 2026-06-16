// Icon-spec → NSImage resolver for facet's hand-drawn views (context
// menus, the tree's badge column, search fields). The convention is
// borrowed from sibling `wand`'s `IconResolver` (its tome panel +
// cast cards) so the same `SF:<name>` spelling works across the family;
// facet only needs the SF-Symbol + text/emoji subset (no app: / favicon:
// / icon-set forms wand carries for its launcher).
//
// WHY BAKE THE TINT IN: facet draws these images directly with
// `NSImage.draw(in:)` inside custom `NSView.draw(_:)` methods (PopupMenu,
// SidebarView), NOT through an `NSImageView` / `NSMenuItem`. AppKit's
// auto-tint of *template* images only happens on the latter path, so a
// template symbol drawn straight would render with whatever the focus
// context's colour is (often near-black, invisible on a dark card). We
// therefore apply the colour via `paletteColors`, which renders the glyph
// as coloured raster pixels that survive a bare `draw(in:)`. (Same trick
// wand uses for its cast-HUD `NSTextAttachment` icons.)

import AppKit
import FacetCore

@MainActor
public enum IconResolver {

    /// Baseline (font-size 13) icon edge in points. Sized a touch above
    /// the 13pt menu text so an SF Symbol reads clearly beside the label.
    /// Paired with `.large` symbol scale (the resolve default) so
    /// whitespace-heavy glyphs (gear / folder / macwindow) optically fill
    /// their box and match tight ones (crown / pin) rather than reading
    /// small — the same calibration wand's tome uses.
    public static let baselinePt: CGFloat = 16

    /// Scale `baselinePt` to a caller's live font size so the icon column
    /// grows with the row (the tree's badge font vs the menu font differ).
    public static func pt(forFontSize fontSize: CGFloat) -> CGFloat {
        (baselinePt * fontSize / 13.0).rounded()
    }

    /// Resolve `spec` to a tinted `NSImage`, or `nil` to draw no icon.
    /// Recognised forms:
    ///   - `""` (empty) — no icon
    ///   - `"SF:<name>"` — SF Symbol (macOS 11+), tinted to `color`
    ///   - anything else — drawn as a centred text / emoji glyph (1–2
    ///     chars typical), tinted to `color`
    /// An unknown SF Symbol name logs once (visible in `/tmp/facet.log`)
    /// and collapses to no icon rather than a fallback box, so a typo is
    /// caught without a placeholder cluttering the row.
    public static func resolve(_ spec: String,
                               pointSize pt: CGFloat,
                               color: NSColor,
                               weight: NSFont.Weight = .medium,
                               scale: NSImage.SymbolScale = .large) -> NSImage? {
        guard !spec.isEmpty else { return nil }
        if spec.hasPrefix("SF:") {
            let name = String(spec.dropFirst(3))
            let cfg = NSImage.SymbolConfiguration(
                pointSize: pt, weight: weight, scale: scale)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            guard let img = NSImage(systemSymbolName: name,
                                    accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) else {
                Log.line("icon-resolver: unknown SF Symbol \"\(name)\" "
                         + "— drawing no icon")
                return nil
            }
            return img
        }
        return textIcon(spec, pointSize: pt, color: color)
    }

    /// Convenience: resolve at a font size (uses `pt(forFontSize:)`).
    public static func resolve(_ spec: String,
                               fontSize: CGFloat,
                               color: NSColor,
                               weight: NSFont.Weight = .medium,
                               scale: NSImage.SymbolScale = .large) -> NSImage? {
        resolve(spec, pointSize: pt(forFontSize: fontSize),
                color: color, weight: weight, scale: scale)
    }

    /// Render `text` (an emoji or 1–2 glyph fallback) centred in a `pt`²
    /// box, tinted to `color`. Used only when the spec isn't an `SF:`
    /// symbol — facet's specs are almost all SF Symbols, so this is the
    /// rare path.
    private static func textIcon(_ text: String,
                                 pointSize pt: CGFloat,
                                 color: NSColor) -> NSImage? {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: pt * 0.9),
            .foregroundColor: color,
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let measured = attributed.size()
        guard measured.width > 0, measured.height > 0 else { return nil }
        let size = NSSize(width: pt, height: pt)
        let img = NSImage(size: size)
        img.lockFocus()
        attributed.draw(at: NSPoint(
            x: (size.width - measured.width) / 2,
            y: (size.height - measured.height) / 2))
        img.unlockFocus()
        return img
    }
}
