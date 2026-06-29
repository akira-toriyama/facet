// Layout / typography constants for the workspace rail.
//
// The rail is a full-screen switcher (like the grid) laid out as a
// Mission-Control-style two-tier: a HERO cell showing the active
// (centred) workspace large, and an edge-docked STRIP that is an
// active-centred carousel of a capped subset of workspaces, each a
// small mini-screen with a grid-style header (name + layout mode +
// grip). A solid black backdrop hides the desktop. Strip/hero split
// and edge are configurable ([rail] strip / cells / edge).

import CoreGraphics
import FacetView
import Foundation

/// Backdrop opacity — solid black so the desktop is fully hidden
/// (matches the grid's takeover feel). Was 0.97 (a hair of translucency
/// for an "overlay opening" read); set opaque per request so neither
/// overview bleeds the desktop through.
let railBackdropAlpha: CGFloat = 1.0

/// Gap between adjacent strip cells, along the strip's running axis.
let railCellGap: CGFloat = 16
/// Sanity floor for a strip cell's short dimension — cells are
/// fixed-size (`[rail] cells` slots), so this only guards a
/// pathologically thin strip, not the old shrink-to-fit chain.
let railCellMinDim: CGFloat = 40
/// Breathing room between a cell and its header.
let railLabelGap: CGFloat = 6
/// Peek depth (points): when the carousel holds more workspaces than the
/// viewport shows, each end reveals this much of the next cell — the
/// both-ends "there's more to rotate to" cue (2-b).
let railPeek: CGFloat = 18

// -- Carousel rotation animation (2-b v2) --
// An arrow rotates the strip by one slot; instead of an instant
// re-layout the strip SLIDES into place. Rapid presses retarget mid-
// flight (the offset accumulates, then eases to 0).
/// Ease-out duration of one rotation slide.
let railSlideDuration: TimeInterval = 0.17
/// Cap the accumulated slide on rapid presses so a key-mash doesn't
/// fling the strip many slots before it eases back.
let railSlideMaxSlots: CGFloat = 3
// (commit zoom-out duration is FacetView's shared `overviewCommitZoomDuration`.)

// -- Responsive layout (orientation- & display-size-aware) --
// The strip / hero proportions and the gaps are derived from the
// SHORT screen edge (so they stay balanced in landscape OR portrait,
// on a laptop OR a big external display). The strip band size itself is
// the user-facing `[rail] strip` percent; these gaps feed the pure
// `railScaledPads` in FacetCore.
//
/// Strip's float off the docked screen edge (fraction of short edge) —
/// keeps the cells from butting against the very edge.
let railEdgeFloatFrac: CGFloat = 0.035
/// Gap between the strip cells and the hero (fraction of short edge) —
/// separates the big preview from the workspace列.
let railHeroGapFrac: CGFloat = 0.05
/// Hero inset from the three outer screen edges + the carousel
/// viewport's run-axis inset (fraction of short edge).
let railOuterFrac: CGFloat = 0.035

/// Rounded mini-screen corner.
let railCellRadius: CGFloat = 8

// -- Header band (grid-style: grip + WS name + layout mode) --
// Smaller clamps than the grid (rail bottom cells are tinier); the
// grip's 3-row compact texture kicks in below 28 pt so it stays legible.
let railHeaderRatio: CGFloat = 0.34     // header ≈ 34% of nominal cell height
let railHeaderMinH: CGFloat = 22
let railHeaderMaxH: CGFloat = 40
let railHeaderGripW: CGFloat = 14
let railHeaderNameFrac: CGFloat = 0.46
let railHeaderNameMinFont: CGFloat = 11
let railHeaderNameMaxFont: CGFloat = 16
let railHeaderModeFrac: CGFloat = 0.34
let railHeaderModeMinFont: CGFloat = 8
let railHeaderModeMaxFont: CGFloat = 12
/// Below this header height a two-line name+mode stack won't fit —
/// fall back to a single name line.
let railHeaderTwoLineMinH: CGFloat = 26

// (drag threshold is FacetView's shared `pointerDragThreshold`.)

// Scroll-wheel delta (points) accumulated per carousel step (⑦). Lower
// = more sensitive (fewer points to advance one workspace). Tune to taste.
let railScrollStep: CGFloat = 30

// -- Board switcher band (t-wrd2): a thin HORIZONTAL tab row, glued to the
//    strip's outer side for top/bottom, at the screen TOP for left/right
//    (a horizontal band can't glue to a vertical side strip). --
/// Band thickness (height) as a fraction of the short screen edge, clamped —
/// lands near the tree band's 30 pt so the chrome reads consistently.
let railBoardBandFrac: CGFloat = 0.030
let railBoardBandMinThick: CGFloat = 26
let railBoardBandMaxThick: CGFloat = 40
/// Tab caption font + horizontal padding inside each tab (→ intrinsic width).
let railBoardFontSize: CGFloat = 12
let railBoardPadX: CGFloat = 10
/// Gap between adjacent tabs + the band's left/right content inset.
let railBoardGap: CGFloat = 4
let railBoardInnerPad: CGFloat = 12
/// Active-tab pill corner radius.
let railBoardRadius: CGFloat = 6
/// Scroll-wheel points accumulated per one board step over the band.
let railBoardWheelStep: CGFloat = 14

/// Centred label size on an empty-WS swap ghost.
let railGhostLabelSize: CGFloat = 22

/// The rail's drag-ghost style: the shared dnd-kit "lift" feedback
/// (DragGhostStyle.overview — values formerly copied from the grid),
/// specialised with the rail's cell corner radius + empty-WS label size.
let railGhostStyle = DragGhostStyle.overview(
    cellCornerRadius: railCellRadius,
    ghostLabelSize: railGhostLabelSize)
