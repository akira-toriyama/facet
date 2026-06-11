// Theme palette — sourced from the shared `sill` library (plan
// atelier). facet's hand-rolled `Palette` struct, its presets,
// `paletteFor`, `blendThrough`, `animatedPalette`, `FontKind`, and the
// `NSColor(hex:)` convenience all live in sill's Palette / PaletteKit /
// Effects modules now — the north star: "facet の theme 真似て" never
// said twice.
//
// These three `@_exported import`s re-publish sill's theming through
// `FacetView`, so every `import FacetView` client (FacetViewTree / Grid /
// Rail / FacetApp) reaches `pal`, `paletteFor(...)`, `uiFont(...)`,
// `borderEffectFor(...)`, etc. WITHOUT a per-file import change. `pal` is
// a PaletteKit `ResolvedPalette`.
//
// Phase V (sill's value redesign) renamed the role fields to a
// Tailwind-style vocabulary — `bg→background`, `text→foreground`,
// `dim→muted`, `accent→primary`, `accent2→secondary`, `divider→border`,
// `hoverFill→hover`, `selFill→selection`, `bgAlpha→backgroundAlpha`
// (`error` / `font` / `tertiary` kept). The view call sites were renamed
// to match in one mechanical pass; the `pal` VAR name itself stays.
//
// What else changed at the seam:
//   * `paletteFor(name)` returns a pure `ThemeSpec`; resolve it with
//     `resolve(_:)` (PaletteKit) before assigning to `pal`.
//   * `animatedPalette(...)` returns an `AnimatedFrame` (the live
//     primary / secondary / selection); the caller folds it onto the
//     base `ResolvedPalette`.
//   * `borderEffectFor(name)` returns a pure `EffectSpec` (UInt32 hex);
//     `BorderFX` resolves it to `NSColor` at configure time.
//   * `pal.tertiary` is a promoted stored field (was a method);
//     `pal.error` and the `.menu` `FontKind` are available too, plus the
//     cross-app `chomp` theme / effect.

@_exported import Palette
@_exported import PaletteKit
@_exported import Effects
