// Layout metrics for the tree sidebar. Kept together at module
// scope so the magic numbers driving spacing are tunable from one
// place. Internal: only SidebarView consumes them.

import CoreGraphics

/// Default sidebar width. Public so the panel host (FacetApp's
/// PanelHost) can pick it up without redefining the number.
/// User-resizable via grip at runtime.
public let sidebarWidth: CGFloat = 248

// Row heights for the different row kinds the sidebar emits.
let headerRowH: CGFloat = 64             // workspace section heading (divider above) — 2-line caption (WS name + layout-mode chip) with breathing room between
let headerFirstRowH: CGFloat = 50        // first workspace: no divider, tighter top, still 2-line caption
let windowRowH: CGFloat = 28             // window row, no title (compact single line)
let handleRowH: CGFloat = 42             // top drag-handle band (panel move + mac desktop label); taller so the divider has padding above/below

// Typography — ONE ordered scale (14 ▸ 13 ▸ 12 ▸ 11). Every tree text
// routes through these constants (no bare literals) so the ladder stays
// consistent: section headers sit ABOVE the body by SIZE; active vs
// inactive (and selected vs not) is signalled by colour + weight at the
// call site, never by a size change — the old `headerFontSize=12` /
// `activeHeaderFontSize=13.5` pair flipped the header size on focus,
// which reflowed the caption and read as the "scattered" look. Integer
// steps only (the half-point 13.5 rendered fuzzy).
let desktopBandFontSize: CGFloat = 14    // "Desktop N" chrome band (HandleBar)
let headerFontSize: CGFloat = 13         // WS caption line 1 (WS name / lens) + search field
let subheadFontSize: CGFloat = 12        // WS caption line 2 (layout-mode label) — subordinate to the name
let windowFontSize: CGFloat = 12         // window-row app name (body text) + DnD chip
let windowTitleFontSize: CGFloat = 11    // window-row title (2nd line)
let badgeFontSize: CGFloat = 12          // mark / tag / status badges (row 3rd line) — body size, but .medium + accent so they still read as metadata

let iconSize: CGFloat = 28               // app icon square
let rowPadX: CGFloat = 12

// Drag-grip glyph at the left of each workspace header — affords
// "grab this workspace to swap its contents" (Theme A). Width is the
// glyph box; the WS name is shifted right by grip + gap.
let headerGripW: CGFloat = 9

// (drag threshold is FacetView's shared `pointerDragThreshold`.)

// Opacity of the lifted DnD snapshot card (⑨) — translucent so the
// drop-target band shows through (dnd-kit style). 0…1.
let dragGhostAlpha: CGFloat = 0.82

// DnD card lean (⑨): radians per point of horizontal drag velocity, and
// the cap. The lifted card tilts toward the drag direction (~10° max).
let dragTiltPerPx: CGFloat = 0.015
let dragTiltMax: CGFloat = 0.18
