// Per-surface palette handle (plan atelier, facet PR-B).
//
// facet's theme used to be a single module-level `pal` (PaletteKit's
// `ResolvedPalette`), read at hundreds of view-side call sites. PR-B
// makes the theme PER-SURFACE: the tree panel, the grid overlay and the
// rail overlay each own their own resolved palette, driven by the config
// keys `[tree]/[grid]/[rail].theme` (`""` / unset = inherit `[theme]`).
//
// A `PaletteBox` is the shared, mutable handle that ties one surface's
// chrome together: the view plus its border / scrollers / overlays /
// popup all hold the SAME box, so a re-theme (hot-reload, `--theme=`) or
// a 30 Hz animator tick updates `box.pal` in ONE place and every reader
// of that surface sees it at once.
//
// Each `pal`-reading class keeps a `paletteBox` and exposes a computed
// `var pal { paletteBox.pal }`. That instance member shadows the legacy
// module-level `pal`, so the existing `pal.foreground` read sites are
// unchanged — they just resolve to the surface's box instead of the
// global. The Controller is the single writer.

import PaletteKit

@MainActor
public final class PaletteBox {
    public var pal: ResolvedPalette
    public init(_ pal: ResolvedPalette) { self.pal = pal }
}
