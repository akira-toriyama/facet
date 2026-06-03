// Layout / animation constants for the overview grid: solid
// black backdrop, thin cell strokes, one compact label per
// cell, no extra index badge.

import CoreGraphics
import Foundation

let gridOuterPad: CGFloat = 48          // overlay edge → outermost cell row
let gridCellGap: CGFloat = 24           // gap between cell rows / cols
let gridCellCornerRadius: CGFloat = 10  // rounded cell shape
let gridLabelGap: CGFloat = 4           // breathing room: label → cell
let gridHeaderGripW: CGFloat = 16       // grip-dot box at left of header band (3 columns of dots)

// Workspace header band sizes PROPORTIONALLY to the cell: fewer
// workspaces → bigger cells → a taller header, and vice-versa, so the
// header stays visually balanced at any workspace count. Height is a
// fraction of the (label-band-free) nominal cell height, clamped so
// two stacked lines (WS name + layout mode) always fit yet the header
// never crowds the thumbs. Both fonts track the resolved band height.
let gridHeaderRatio: CGFloat = 0.08     // band height ≈ 8% of nominal cell height — matches the tree's bumped two-line breathing room
let gridHeaderMinH: CGFloat = 32        // floor fits two small text lines with the new breathing
let gridHeaderMaxH: CGFloat = 64        // pairs with the tree's bumped headerRowH (64 pt)
let gridHeaderNameFrac: CGFloat = 0.34  // WS-name font ≈ 34% of band height
let gridHeaderNameMinFont: CGFloat = 13
let gridHeaderNameMaxFont: CGFloat = 24
let gridHeaderModeFrac: CGFloat = 0.24  // layout-mode font ≈ 24% of band height
let gridHeaderModeMinFont: CGFloat = 9
let gridHeaderModeMaxFont: CGFloat = 16
let gridGhostLabelSize: CGFloat = 30    // centred label on an empty-WS swap ghost

// Public so FacetApp's Controller can configure the GridOverlay
// fade timing without redefining the numbers.
public let gridBackdropAlpha: CGFloat = 1.0    // overlay opacity (solid black)
public let gridFadeIn: TimeInterval = 0.12     // overlay fade-in
public let gridFadeOut: TimeInterval = 0.10    // overlay fade-out

// dnd-kit-style "lift" feedback when a drag starts: ghost grows
// slightly + soft shadow drops in so the user *feels* the thumb
// being picked up. Cursor-follow path is paused for the duration so
// the animation isn't yanked mid-frame.
let gridLiftScale: CGFloat = 1.06
let gridLiftDuration: TimeInterval = 0.14
let gridLiftShadowRadius: CGFloat = 14
let gridLiftShadowOpacity: Float = 0.45

// dnd-kit-style "animated reorder" after a successful drop: every
// window thumb whose rect changed slides from its old rect to its
// new rect over this duration with an ease-out curve (FLIP).
let gridReorderDuration: TimeInterval = 0.15

// Pointer distance (px) before a mouseDown becomes a drag. Same
// value as FacetViewTree's tunable — kept module-local in both
// places to avoid a cross-module import for one constant.
let dragThreshold: CGFloat = 5
