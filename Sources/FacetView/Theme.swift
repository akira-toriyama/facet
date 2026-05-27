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
