// Theme palette — now sourced from the shared `sill` library (plan
// atelier). facet's hand-rolled `Palette` struct, its 22 presets,
// `paletteFor`, `blendThrough`, `animatedPalette`, `FontKind`, and the
// `NSColor(hex:)` convenience all moved to sill's Palette / PaletteKit /
// Effects modules — the north star: "facet の theme 真似て" never said
// twice.
//
// These three `@_exported import`s re-publish sill's theming through
// `FacetView`, so every `import FacetView` client (FacetViewTree / Grid /
// Rail / FacetApp) keeps reading `pal.text`, calling `paletteFor(...)`,
// `uiFont(...)`, `borderEffectFor(...)`, etc. WITHOUT a per-file import
// change. `pal` is now a PaletteKit `ResolvedPalette` whose field names
// match facet's old `Palette`, so the hundreds of `pal.text` / `pal.dim`
// call sites are untouched.
//
// What changed at the seam (see the migration notes in the PR):
//   * `paletteFor(name)` now returns a pure `ThemeSpec`; resolve it with
//     `resolve(_:)` (PaletteKit) before assigning to `pal`.
//   * `animatedPalette(...)` now returns an `AnimatedFrame` (the live
//     accent / accent2 / selFill); the caller folds it onto the base
//     `ResolvedPalette`.
//   * `borderEffectFor(name)` now returns a pure `EffectSpec` (UInt32
//     hex); `BorderFX` resolves it to `NSColor` at configure time.
//   * New, available for free: `pal.error`, `pal.tertiary()`, the `.menu`
//     `FontKind`, and the cross-app `chomp` theme / effect.

@_exported import Palette
@_exported import PaletteKit
@_exported import Effects
