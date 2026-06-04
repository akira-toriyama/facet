// Theme palette. CLI flag `--theme=terminal|cute|system` picks one
// at startup; views read it from the module-level `pal` (Theme.swift).

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
    /// Secondary accent — a distinct hue from `accent`, reserved
    /// for status badges that should NOT share the primary-accent
    /// signal used by the active WS name / kbNav outline. Drives
    /// the tree's mode + master/float chips (accent-2 text on a
    /// 15 %-alpha accent-2 fill).
    public let accent2: NSColor
    public let divider: NSColor
    public let hoverFill: NSColor
    public let selFill: NSColor
    public let font: FontKind
    /// Right-click menu appearance — keeps the AppKit-rendered menu
    /// matching the panel's theme even when the system appearance
    /// differs.
    public let menuAppearance: NSAppearance.Name?

    public init(bg: NSColor?, text: NSColor, dim: NSColor,
                accent: NSColor, accent2: NSColor, divider: NSColor,
                hoverFill: NSColor, selFill: NSColor,
                font: FontKind, menuAppearance: NSAppearance.Name?) {
        self.bg = bg
        self.text = text
        self.dim = dim
        self.accent = accent
        self.accent2 = accent2
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
    /// `accent2` is the Tokyo-Night purple — a distinct hue from
    /// the green primary, so status chips (mode / master / float)
    /// don't fight the active-WS green.
    static let terminal = Palette(
        bg: NSColor(hex: 0x0E0F14), text: NSColor(hex: 0xC0CAF5),
        dim: NSColor(hex: 0x6B7394), accent: NSColor(hex: 0x9ECE6A),
        accent2: NSColor(hex: 0xBB9AF7),
        divider: NSColor.white.withAlphaComponent(0.10),
        hoverFill: NSColor.white.withAlphaComponent(0.05),
        selFill: NSColor(hex: 0x9ECE6A).withAlphaComponent(0.18),
        font: .mono, menuAppearance: .darkAqua)

    /// Soft pastel, rounded. `accent2` is a peach that sits warmly
    /// next to the pink primary without competing.
    static let cute = Palette(
        bg: NSColor(hex: 0xFFF1F6), text: NSColor(hex: 0x6B5566),
        dim: NSColor(hex: 0xB892A6), accent: NSColor(hex: 0xF2789F),
        accent2: NSColor(hex: 0xFFB48F),
        divider: NSColor(hex: 0xF2789F, 0.22),
        hoverFill: NSColor(hex: 0xF2789F, 0.10),
        selFill: NSColor(hex: 0xF2789F, 0.20),
        font: .rounded, menuAppearance: .aqua)

    /// Native vibrancy + dynamic system colors. `accent2` is
    /// `.systemPurple` — a stable system hue that contrasts with
    /// whatever the user picked for `.controlAccentColor` (usually
    /// blue).
    static let system = Palette(
        bg: nil, text: .labelColor, dim: .secondaryLabelColor,
        accent: .controlAccentColor,
        accent2: .systemPurple,
        divider: NSColor.labelColor.withAlphaComponent(0.22),
        hoverFill: NSColor.secondaryLabelColor.withAlphaComponent(0.12),
        selFill: NSColor.controlAccentColor.withAlphaComponent(0.22),
        font: .system, menuAppearance: nil)

    // --- Added themes ----------------------------------------------
    // Dark, monospace editor palettes. Each follows the `terminal`
    // recipe: white-alpha neutrals (divider 0.10 / hover 0.05) and a
    // selFill of the primary accent at 0.18. `accent` is the primary
    // signal (active WS / kbNav); `accent2` a complementary hue for
    // status chips. Hex values are each palette's published source.

    /// Nord — cool polar-night blue-grey. Frost-cyan primary; the
    /// aurora sand-yellow `accent2` is its warm complement.
    static let nord = Palette(
        bg: NSColor(hex: 0x2E3440), text: NSColor(hex: 0xECEFF4),
        dim: NSColor(hex: 0x7B88A1), accent: NSColor(hex: 0x88C0D0),
        accent2: NSColor(hex: 0xEBCB8B),
        divider: NSColor.white.withAlphaComponent(0.10),
        hoverFill: NSColor.white.withAlphaComponent(0.05),
        selFill: NSColor(hex: 0x88C0D0).withAlphaComponent(0.18),
        font: .mono, menuAppearance: .darkAqua)

    /// Dracula — vivid dark. Purple primary, green `accent2`.
    static let dracula = Palette(
        bg: NSColor(hex: 0x282A36), text: NSColor(hex: 0xF8F8F2),
        dim: NSColor(hex: 0x6272A4), accent: NSColor(hex: 0xBD93F9),
        accent2: NSColor(hex: 0x50FA7B),
        divider: NSColor.white.withAlphaComponent(0.10),
        hoverFill: NSColor.white.withAlphaComponent(0.05),
        selFill: NSColor(hex: 0xBD93F9).withAlphaComponent(0.18),
        font: .mono, menuAppearance: .darkAqua)

    /// Gruvbox — retro warm dark. Orange primary, aqua `accent2`.
    static let gruvbox = Palette(
        bg: NSColor(hex: 0x282828), text: NSColor(hex: 0xEBDBB2),
        dim: NSColor(hex: 0x928374), accent: NSColor(hex: 0xFE8019),
        accent2: NSColor(hex: 0x8EC07C),
        divider: NSColor.white.withAlphaComponent(0.10),
        hoverFill: NSColor.white.withAlphaComponent(0.05),
        selFill: NSColor(hex: 0xFE8019).withAlphaComponent(0.18),
        font: .mono, menuAppearance: .darkAqua)

    /// Catppuccin Mocha — soft pastel dark. Mauve primary, green
    /// `accent2`.
    static let catppuccin = Palette(
        bg: NSColor(hex: 0x1E1E2E), text: NSColor(hex: 0xCDD6F4),
        dim: NSColor(hex: 0x7F849C), accent: NSColor(hex: 0xCBA6F7),
        accent2: NSColor(hex: 0xA6E3A1),
        divider: NSColor.white.withAlphaComponent(0.10),
        hoverFill: NSColor.white.withAlphaComponent(0.05),
        selFill: NSColor(hex: 0xCBA6F7).withAlphaComponent(0.18),
        font: .mono, menuAppearance: .darkAqua)

    /// Rosé Pine — muted aubergine dark. Iris primary, rose `accent2`.
    static let rosepine = Palette(
        bg: NSColor(hex: 0x191724), text: NSColor(hex: 0xE0DEF4),
        dim: NSColor(hex: 0x908CAA), accent: NSColor(hex: 0xC4A7E7),
        accent2: NSColor(hex: 0xEBBCBA),
        divider: NSColor.white.withAlphaComponent(0.10),
        hoverFill: NSColor.white.withAlphaComponent(0.05),
        selFill: NSColor(hex: 0xC4A7E7).withAlphaComponent(0.18),
        font: .mono, menuAppearance: .darkAqua)

    /// Everforest — soft forest dark. Green primary, orange `accent2`.
    static let everforest = Palette(
        bg: NSColor(hex: 0x2D353B), text: NSColor(hex: 0xD3C6AA),
        dim: NSColor(hex: 0x859289), accent: NSColor(hex: 0xA7C080),
        accent2: NSColor(hex: 0xE69875),
        divider: NSColor.white.withAlphaComponent(0.10),
        hoverFill: NSColor.white.withAlphaComponent(0.05),
        selFill: NSColor(hex: 0xA7C080).withAlphaComponent(0.18),
        font: .mono, menuAppearance: .darkAqua)

    /// Solarized Dark — classic teal-base. Blue primary, orange
    /// `accent2` (its complement).
    static let solarized = Palette(
        bg: NSColor(hex: 0x002B36), text: NSColor(hex: 0x93A1A1),
        dim: NSColor(hex: 0x586E75), accent: NSColor(hex: 0x268BD2),
        accent2: NSColor(hex: 0xCB4B16),
        divider: NSColor.white.withAlphaComponent(0.10),
        hoverFill: NSColor.white.withAlphaComponent(0.05),
        selFill: NSColor(hex: 0x268BD2).withAlphaComponent(0.18),
        font: .mono, menuAppearance: .darkAqua)

    /// One Dark — Atom's signature dark. Blue primary, yellow `accent2`.
    static let onedark = Palette(
        bg: NSColor(hex: 0x282C34), text: NSColor(hex: 0xABB2BF),
        dim: NSColor(hex: 0x5C6370), accent: NSColor(hex: 0x61AFEF),
        accent2: NSColor(hex: 0xE5C07B),
        divider: NSColor.white.withAlphaComponent(0.10),
        hoverFill: NSColor.white.withAlphaComponent(0.05),
        selFill: NSColor(hex: 0x61AFEF).withAlphaComponent(0.18),
        font: .mono, menuAppearance: .darkAqua)

    /// Monokai — high-energy dark. Lime primary, magenta `accent2`.
    static let monokai = Palette(
        bg: NSColor(hex: 0x272822), text: NSColor(hex: 0xF8F8F2),
        dim: NSColor(hex: 0x75715E), accent: NSColor(hex: 0xA6E22E),
        accent2: NSColor(hex: 0xF92672),
        divider: NSColor.white.withAlphaComponent(0.10),
        hoverFill: NSColor.white.withAlphaComponent(0.05),
        selFill: NSColor(hex: 0xA6E22E).withAlphaComponent(0.18),
        font: .mono, menuAppearance: .darkAqua)

    /// Paper — clean daytime light (not cute). Blue primary with an
    /// amber complement (the Zenn primary+補色 example); neutral
    /// black-alpha dividers keep the page calm. System font.
    static let paper = Palette(
        bg: NSColor(hex: 0xFAFAF8), text: NSColor(hex: 0x1C1C1E),
        dim: NSColor(hex: 0x8A8A8E), accent: NSColor(hex: 0x3B82F6),
        accent2: NSColor(hex: 0xF59E0B),
        divider: NSColor.black.withAlphaComponent(0.10),
        hoverFill: NSColor.black.withAlphaComponent(0.04),
        selFill: NSColor(hex: 0x3B82F6).withAlphaComponent(0.14),
        font: .system, menuAppearance: .aqua)

    // --- Monochrome --------------------------------------------------
    // Greyscale sets. The primary/secondary accents collapse to two
    // shades (darkest = primary signal, a lighter grey = secondary)
    // — deliberate for a monochrome look. The stark B&W pair uses the
    // mono font; `monotone` softens to system font + mid-greys.

    /// 白黒 — stark black-on-white. Pure-black primary, dark-grey
    /// `accent2`; mono font for a paper-terminal feel.
    static let monoLight = Palette(
        bg: NSColor(hex: 0xFFFFFF), text: NSColor(hex: 0x111111),
        dim: NSColor(hex: 0x8A8A8A), accent: NSColor(hex: 0x000000),
        accent2: NSColor(hex: 0x555555),
        divider: NSColor.black.withAlphaComponent(0.14),
        hoverFill: NSColor.black.withAlphaComponent(0.05),
        selFill: NSColor.black.withAlphaComponent(0.10),
        font: .mono, menuAppearance: .aqua)

    /// 黒白 — stark white-on-black (OLED). White primary, light-grey
    /// `accent2`; mono font.
    static let monoDark = Palette(
        bg: NSColor(hex: 0x000000), text: NSColor(hex: 0xF5F5F5),
        dim: NSColor(hex: 0x777777), accent: NSColor(hex: 0xFFFFFF),
        accent2: NSColor(hex: 0xAAAAAA),
        divider: NSColor.white.withAlphaComponent(0.14),
        hoverFill: NSColor.white.withAlphaComponent(0.06),
        selFill: NSColor.white.withAlphaComponent(0.16),
        font: .mono, menuAppearance: .darkAqua)

    /// モノトーン — soft graphite greyscale; no pure black/white.
    /// Mid-grey accents + system font for a calmer, lower-contrast
    /// monochrome than the stark mono-light / mono-dark pair.
    static let monotone = Palette(
        bg: NSColor(hex: 0x1E1E1E), text: NSColor(hex: 0xC8C8C8),
        dim: NSColor(hex: 0x7A7A7A), accent: NSColor(hex: 0xB0B0B0),
        accent2: NSColor(hex: 0x888888),
        divider: NSColor.white.withAlphaComponent(0.10),
        hoverFill: NSColor.white.withAlphaComponent(0.05),
        selFill: NSColor(hex: 0xB0B0B0).withAlphaComponent(0.18),
        font: .system, menuAppearance: .darkAqua)

    /// Black base with a neon-green primary + amber secondary — a
    /// green-on-black hacker-terminal look (amber over red: far more
    /// legible on black, and a classic green/amber terminal pairing).
    /// Green = active WS / kbNav, amber = status chips. mono font.
    static let hacker = Palette(
        bg: NSColor(hex: 0x0A0F0A), text: NSColor(hex: 0xCFE0CF),
        dim: NSColor(hex: 0x5F715F), accent: NSColor(hex: 0x33FF66),
        accent2: NSColor(hex: 0xFFC857),
        divider: NSColor.white.withAlphaComponent(0.10),
        hoverFill: NSColor.white.withAlphaComponent(0.05),
        selFill: NSColor(hex: 0x33FF66).withAlphaComponent(0.18),
        font: .mono, menuAppearance: .darkAqua)

    // --- Neon family -------------------------------------------------
    // Vivid electric themes. The signature hue is the bright `accent`
    // (active WS / kbNav); `bg` is near-black tinted with the theme hue
    // so the accent pops, and `text` is a desaturated light tint (never
    // the raw neon) to stay readable. `neon`/`cyber`/`vapor` pair a
    // cool primary with the opposite neon (cyan↔magenta) for chips;
    // `kawaii` is the light-pastel exception (candy lavender, distinct
    // from `cute`'s pink). These names also exist as `[border] effect`s
    // — `--theme=` (palette) and `[border] effect` are orthogonal axes,
    // so the shared token is intentional, not a clash.

    /// Neon — electric cyan on blue-black; hot-magenta secondary.
    static let neon = Palette(
        bg: NSColor(hex: 0x0A0A14), text: NSColor(hex: 0xC0CAF5),
        dim: NSColor(hex: 0x6B7394), accent: NSColor(hex: 0x00E5FF),
        accent2: NSColor(hex: 0xFF2EC4),
        divider: NSColor.white.withAlphaComponent(0.10),
        hoverFill: NSColor.white.withAlphaComponent(0.05),
        selFill: NSColor(hex: 0x00E5FF).withAlphaComponent(0.18),
        font: .mono, menuAppearance: .darkAqua)

    /// Cyber — aqua/teal on teal-black; hot-pink secondary (teal × pink).
    static let cyber = Palette(
        bg: NSColor(hex: 0x001410), text: NSColor(hex: 0xC8F0E4),
        dim: NSColor(hex: 0x5F8076), accent: NSColor(hex: 0x00FFD0),
        accent2: NSColor(hex: 0xFF3DCE),
        divider: NSColor.white.withAlphaComponent(0.10),
        hoverFill: NSColor.white.withAlphaComponent(0.05),
        selFill: NSColor(hex: 0x00FFD0).withAlphaComponent(0.18),
        font: .mono, menuAppearance: .darkAqua)

    /// Vapor — synthwave pink on purple-black; electric-cyan secondary.
    static let vapor = Palette(
        bg: NSColor(hex: 0x1A0E26), text: NSColor(hex: 0xEAD9F5),
        dim: NSColor(hex: 0x8A6FA6), accent: NSColor(hex: 0xFF6AD5),
        accent2: NSColor(hex: 0x05D9E8),
        divider: NSColor.white.withAlphaComponent(0.10),
        hoverFill: NSColor.white.withAlphaComponent(0.05),
        selFill: NSColor(hex: 0xFF6AD5).withAlphaComponent(0.18),
        font: .mono, menuAppearance: .darkAqua)

    /// Kawaii — candy lavender light (the light-pastel exception);
    /// purple primary + mint secondary, distinct from `cute`'s pink.
    static let kawaii = Palette(
        bg: NSColor(hex: 0xFAF0FF), text: NSColor(hex: 0x5E5470),
        dim: NSColor(hex: 0xA99BC0), accent: NSColor(hex: 0xB661E8),
        accent2: NSColor(hex: 0x7DD9C0),
        divider: NSColor(hex: 0xB661E8, 0.20),
        hoverFill: NSColor(hex: 0xB661E8, 0.10),
        selFill: NSColor(hex: 0xB661E8, 0.18),
        font: .rounded, menuAppearance: .aqua)

    /// Rainbow — a deliberately loud, maximum-saturation set; readability
    /// is explicitly secondary (per request). White on a near-black violet
    /// so the vivid rose primary + electric-cyan secondary blaze. Rounded
    /// for a playful feel. (Pair with `[border] effect = "rainbow"` for the
    /// actually-cycling hue; this palette itself is static.)
    static let rainbow = Palette(
        bg: NSColor(hex: 0x0D0B14), text: NSColor(hex: 0xFFFFFF),
        dim: NSColor(hex: 0x8C84B0), accent: NSColor(hex: 0xFF2D95),
        accent2: NSColor(hex: 0x2BE0FF),
        divider: NSColor.white.withAlphaComponent(0.14),
        hoverFill: NSColor.white.withAlphaComponent(0.07),
        selFill: NSColor(hex: 0xFF2D95).withAlphaComponent(0.22),
        font: .rounded, menuAppearance: .darkAqua)
}

/// Canonical theme names accepted by `--theme=`. Single source of
/// truth so the CLI can reject typos instead of silently falling
/// back to the default (see `paletteFor`).
public let canonicalStyles = [
    "terminal", "cute", "system",
    "nord", "dracula", "gruvbox", "catppuccin", "rosepine",
    "everforest", "solarized", "onedark", "monokai", "hacker", "paper",
    "mono-light", "mono-dark", "monotone",
    "neon", "cyber", "vapor", "kawaii", "rainbow",
    "random",   // meta: picks a random concrete theme at resolve time
]

public let defaultStyleName = "terminal"

/// Map a raw `--theme=…` value to a `Palette`. Case-insensitive;
/// unknown names fall through to `terminal` (the default).
@MainActor
public func paletteFor(_ raw: String) -> Palette {
    switch raw.lowercased() {
    case "cute":       return .cute
    case "system":     return .system
    case "nord":       return .nord
    case "dracula":    return .dracula
    case "gruvbox":    return .gruvbox
    case "catppuccin": return .catppuccin
    case "rosepine":   return .rosepine
    case "everforest": return .everforest
    case "solarized":  return .solarized
    case "onedark":    return .onedark
    case "monokai":    return .monokai
    case "hacker":     return .hacker
    case "neon":       return .neon
    case "cyber":      return .cyber
    case "vapor":      return .vapor
    case "kawaii":     return .kawaii
    case "rainbow":    return .rainbow
    case "paper":      return .paper
    case "mono-light": return .monoLight
    case "mono-dark":  return .monoDark
    case "monotone":   return .monotone
    case "random":
        // Pick a random concrete color theme each time this resolves
        // (startup + every --reload). Excludes the "random" sentinel
        // itself and "system" (the adaptive native look), per request.
        let pool = canonicalStyles.filter {
            $0 != "random" && $0 != "system"
        }
        return paletteFor(pool.randomElement() ?? "terminal")
    default:           return .terminal
    }
}

/// Smoothly loop through `colors` by `phase` (0…1), blending consecutive
/// entries. Shared by the border cycle (⑧) and the theme cycle (⑪).
public func blendThrough(_ colors: [NSColor], at phase: CGFloat) -> NSColor {
    let n = colors.count
    guard n > 1 else { return colors.first ?? .white }
    let p = phase - floor(phase)
    let scaled = p * CGFloat(n)
    let i = Int(scaled) % n
    let t = scaled - floor(scaled)
    return colors[i].blended(withFraction: t, of: colors[(i + 1) % n]) ?? colors[i]
}

/// An animatable theme cycled to `phase` (0…1), or nil if `theme` isn't
/// one (⑪). `rainbow` rotates `accent` through the full spectrum;
/// `neon` / `cyber` / `vapor` / `kawaii` cycle it through the matching
/// border effect's own flash palette (keeping their identity). `accent2`
/// trails half a turn; `bg` / `text` stay put so the UI stays usable.
@MainActor
public func animatedPalette(theme: String, at phase: CGFloat) -> Palette? {
    let key = theme.lowercased()
    let base = paletteFor(key)
    let h = phase - floor(phase)
    let h2 = (h + 0.5).truncatingRemainder(dividingBy: 1)
    let accent: NSColor, accent2: NSColor
    if key == "rainbow" {
        accent  = NSColor(hue: h,  saturation: 0.95, brightness: 1, alpha: 1)
        accent2 = NSColor(hue: h2, saturation: 0.95, brightness: 1, alpha: 1)
    } else if let fx = borderEffectFor(key), !fx.flash.isEmpty {
        accent  = blendThrough(fx.flash, at: h)
        accent2 = blendThrough(fx.flash, at: h2)
    } else {
        return nil
    }
    return Palette(bg: base.bg, text: base.text, dim: base.dim,
                   accent: accent, accent2: accent2,
                   divider: base.divider, hoverFill: base.hoverFill,
                   selFill: accent.withAlphaComponent(0.22),
                   font: base.font, menuAppearance: base.menuAppearance)
}
