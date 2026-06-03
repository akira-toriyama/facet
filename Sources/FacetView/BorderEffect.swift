// Tree-panel border effects. The `[border] effect` config key
// (FacetConfig.effectiveBorderEffect) selects one by name; PanelHost
// paints `steady` as the resting border and (PR-2) blinks through
// `flash` on a workspace switch. Independent of `theme` — an effect
// layers on top of whatever palette is active.
//
// `theme 以外もあり`: this is the non-theme knob the neon border asked
// for. Keep the name set here in sync with the `known` list in
// FacetCore's `effectiveBorderEffect` (FacetCore can't import these
// NSColors, so the validation list is duplicated there).

import AppKit

/// One border effect: a resting border color plus the palette the
/// WS-switch flash blinks through. `cycles` slowly rotates the steady
/// hue (rainbow) — driven by PanelHost's animation loop.
public struct BorderEffect: Sendable {
    public let steady: NSColor
    public let flash: [NSColor]
    public let cycles: Bool

    public init(steady: NSColor, flash: [NSColor], cycles: Bool = false) {
        self.steady = steady
        self.flash = flash
        self.cycles = cycles
    }
}

/// Map a `[border] effect` name to its effect, or `nil` for "off" /
/// unknown (PanelHost then falls back to the plain theme-accent
/// border). `@MainActor` because `NSColor` isn't `Sendable` under
/// Swift 6 strict concurrency (same reason the `Palette` presets are).
@MainActor
public func borderEffectFor(_ name: String) -> BorderEffect? {
    switch name.lowercased() {
    case "neon":
        // Tokyo-Night blue at rest; electric neon flashes (eventfx
        // NEON palette).
        return BorderEffect(
            steady: NSColor(hex: 0x7AA2F7),
            flash: [0x00E5FF, 0xFF00FF, 0x39FF14,
                    0xFE019A, 0x04D9FF, 0xBC13FE].map { NSColor(hex: $0) })
    case "cyber":
        // Teal/aqua matrix feel.
        return BorderEffect(
            steady: NSColor(hex: 0x00FFD0),
            flash: [0x00FFD0, 0x00E5FF, 0x39FF14,
                    0x14FFEC, 0x00FF9C, 0x0AFFFF].map { NSColor(hex: $0) })
    case "vapor":
        // Synthwave pink → purple → cyan.
        return BorderEffect(
            steady: NSColor(hex: 0xFF6AD5),
            flash: [0xFF6AD5, 0xC774E8, 0xAD8CFF,
                    0x8795E8, 0x94D0FF, 0xFF71CE].map { NSColor(hex: $0) })
    case "kawaii":
        // Soft pastels (eventfx KAWAII palette).
        return BorderEffect(
            steady: NSColor(hex: 0xFFB3D9),
            flash: [0xFFB3D9, 0xD9B3FF, 0xB3FFD9,
                    0xFFE0B3, 0xB3E0FF, 0xFFC6E0].map { NSColor(hex: $0) })
    case "rainbow":
        // Full spectrum; `cycles` slowly rotates the resting hue.
        return BorderEffect(
            steady: NSColor(hex: 0xFF3B30),
            flash: [0xFF0000, 0xFF7F00, 0xFFFF00, 0x00FF00,
                    0x00FFFF, 0x0000FF, 0x8B00FF].map { NSColor(hex: $0) },
            cycles: true)
    default:   // "off" or unknown
        return nil
    }
}
