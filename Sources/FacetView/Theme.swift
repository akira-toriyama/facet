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
