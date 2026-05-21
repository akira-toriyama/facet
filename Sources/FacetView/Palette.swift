// Theme palette. CLI flag `--theme=terminal|cute|system` picks one
// at startup; views read it from the module-level `pal` (Theme.swift).
// Lifted from ws-tabs essentially verbatim — colors are the canonical
// look that v1.x users already know.

import AppKit

public extension NSColor {
    /// Convenience initializer that takes an RGB hex as `0xRRGGBB`.
    /// Alpha defaults to 1.
    convenience init(hex: UInt32, _ a: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green:   CGFloat((hex >> 8)  & 0xff) / 255,
                  blue:    CGFloat( hex        & 0xff) / 255,
                  alpha:   a)
    }
}

public enum FontKind: Sendable {
    case system, mono, rounded
}

/// One full color/typography set. `bg == nil` means "fall through to
/// system vibrancy" (used by the `system` preset).
public struct Palette {
    public let bg: NSColor?
    public let text: NSColor
    public let dim: NSColor
    public let accent: NSColor
    public let divider: NSColor
    public let hoverFill: NSColor
    public let selFill: NSColor
    public let font: FontKind
    /// Right-click menu appearance — keeps the AppKit-rendered menu
    /// matching the panel's theme even when the system appearance
    /// differs.
    public let menuAppearance: NSAppearance.Name?

    public init(bg: NSColor?, text: NSColor, dim: NSColor,
                accent: NSColor, divider: NSColor,
                hoverFill: NSColor, selFill: NSColor,
                font: FontKind, menuAppearance: NSAppearance.Name?) {
        self.bg = bg
        self.text = text
        self.dim = dim
        self.accent = accent
        self.divider = divider
        self.hoverFill = hoverFill
        self.selFill = selFill
        self.font = font
        self.menuAppearance = menuAppearance
    }
}

// NSColor isn't Sendable in Swift 6 strict concurrency, so the
// preset palettes can't be ordinary top-level lets — they must be
// MainActor-isolated. View code is @MainActor anyway, so this matches
// how the presets are actually consumed.
@MainActor
public extension Palette {
    /// Default. Near-black background, Tokyo-Night-ish accents, mono.
    static let terminal = Palette(
        bg: NSColor(hex: 0x0E0F14), text: NSColor(hex: 0xC0CAF5),
        dim: NSColor(hex: 0x6B7394), accent: NSColor(hex: 0x9ECE6A),
        divider: NSColor.white.withAlphaComponent(0.10),
        hoverFill: NSColor.white.withAlphaComponent(0.05),
        selFill: NSColor(hex: 0x9ECE6A).withAlphaComponent(0.18),
        font: .mono, menuAppearance: .darkAqua)

    /// Soft pastel, rounded.
    static let cute = Palette(
        bg: NSColor(hex: 0xFFF1F6), text: NSColor(hex: 0x6B5566),
        dim: NSColor(hex: 0xB892A6), accent: NSColor(hex: 0xF2789F),
        divider: NSColor(hex: 0xF2789F, 0.22),
        hoverFill: NSColor(hex: 0xF2789F, 0.10),
        selFill: NSColor(hex: 0xF2789F, 0.20),
        font: .rounded, menuAppearance: .aqua)

    /// Native vibrancy + dynamic system colors.
    static let system = Palette(
        bg: nil, text: .labelColor, dim: .secondaryLabelColor,
        accent: .controlAccentColor,
        divider: NSColor.labelColor.withAlphaComponent(0.22),
        hoverFill: NSColor.secondaryLabelColor.withAlphaComponent(0.12),
        selFill: NSColor.controlAccentColor.withAlphaComponent(0.22),
        font: .system, menuAppearance: nil)
}

/// Canonical theme names accepted by `--theme=`. Single source of
/// truth so the CLI can reject typos instead of silently falling
/// back to the default (see `paletteFor`).
public let canonicalStyles = ["terminal", "cute", "system"]

public let defaultStyleName = "terminal"

/// Map a raw `--theme=…` value to a `Palette`. Case-insensitive;
/// unknown names fall through to `terminal` (the default).
@MainActor
public func paletteFor(_ raw: String) -> Palette {
    switch raw.lowercased() {
    case "cute":   return .cute
    case "system": return .system
    default:       return .terminal
    }
}
