// Layout / animation constants for the overview grid. The cell chrome
// (corner radius, cell gap, outer pad, drop rings, drag ghost) is sill's
// — `ThemedGridView` owns those tokens now — so what remains here is the
// grid's OWN anatomy: the proportional workspace-header band and the
// FLIP reorder timing.

import CoreGraphics
import Foundation

let gridLabelGap: CGFloat = 4           // breathing room: label → mini-screen

// Workspace header band sizes PROPORTIONALLY to the cell: fewer
// workspaces → bigger cells → a taller header, and vice-versa, so the
// header stays visually balanced at any workspace count. Height is a
// fraction of the (label-band-free) nominal cell height, clamped so
// two stacked lines (WS name + layout mode) always fit yet the header
// never crowds the thumbs. Both fonts track the resolved band height.
let gridHeaderRatio: CGFloat = 0.08     // band height ≈ 8% of nominal cell height
let gridHeaderMinH: CGFloat = 32        // floor fits two small text lines
let gridHeaderMaxH: CGFloat = 64        // pairs with the tree's headerRowH (64 pt)
let gridHeaderNameFrac: CGFloat = 0.34  // WS-name font ≈ 34% of band height
let gridHeaderNameMinFont: CGFloat = 13
let gridHeaderNameMaxFont: CGFloat = 24
let gridHeaderModeFrac: CGFloat = 0.24  // layout-mode font ≈ 24% of band height
let gridHeaderModeMinFont: CGFloat = 9
let gridHeaderModeMaxFont: CGFloat = 16
let gridHeaderGripW: CGFloat = 16       // grip-dot box at left of the header band

// Public so FacetApp's Controller can paint the shell's backdrop without
// redefining the number. (The overlay fade timing is shared with the
// rail — see `overviewFadeIn` / `overviewFadeOut` in FacetView's
// SharedTunables; only this near-black backdrop alpha is grid-specific.)
public let gridBackdropAlpha: CGFloat = 1.0    // overlay opacity (solid black)

// dnd-kit-style "animated reorder" after a successful drop: every
// window thumb whose rect changed slides from its old rect to its
// new rect over this duration with an ease-out curve (FLIP).
let gridReorderDuration: TimeInterval = 0.15
