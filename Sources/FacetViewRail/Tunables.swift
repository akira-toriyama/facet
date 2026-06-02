// Layout / typography constants for the workspace rail.
//
// The rail is a full-screen overview (like the grid) but laid out as
// a Mission-Control-style two-tier: a HERO cell in the centre showing
// the active workspace large, and a ROW of every workspace along the
// bottom — each a small mini-screen with a grid-style header (name +
// layout mode + grip). A near-black backdrop hides the desktop.

import CoreGraphics
import Foundation

/// Backdrop opacity — near-opaque so the desktop is hidden (matches
/// the grid's takeover feel) while a hair of translucency keeps the
/// fade reading as "overlay opening," not "screen blanked."
let railBackdropAlpha: CGFloat = 0.97

/// Outer padding: screen edge → content.
let railOuterPad: CGFloat = 40
/// Gap between adjacent strip cells, along the strip's running axis.
let railCellGap: CGFloat = 16
/// Sanity floor for a strip cell's short dimension — cells are
/// fixed-size (`[rail] cells` slots), so this only guards a
/// pathologically thin strip, not the old shrink-to-fit chain.
let railCellMinDim: CGFloat = 40
/// Breathing room between a cell and its header.
let railLabelGap: CGFloat = 6

/// Strip thickness — the all-workspaces band's cross-axis size (height
/// for a top/bottom rail, width for left/right) as a fraction of that
/// screen dimension. The hero fills the rest.
let railStripSizeFrac: CGFloat = 0.30

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

// Pointer distance (px) before a mouseDown becomes a drag (Phase R2/R3
// — drag a window thumbnail / a header between cells). Same value as
// the grid / tree tunables; kept module-local.
let railDragThreshold: CGFloat = 5

// -- Drag "lift" feedback (copy of the grid's values): the ghost is
//    installed already at lifted size + a soft shadow fades in. --
let railLiftScale: CGFloat = 1.06
let railLiftDuration: TimeInterval = 0.14
let railLiftShadowRadius: CGFloat = 14
let railLiftShadowOpacity: Float = 0.45
/// Centred label size on an empty-WS swap ghost.
let railGhostLabelSize: CGFloat = 22
