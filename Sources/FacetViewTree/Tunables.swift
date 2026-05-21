// Layout metrics for the tree sidebar. Kept together at module
// scope so the magic numbers driving spacing are tunable from one
// place. Internal: only SidebarView consumes them.

import CoreGraphics

/// Default sidebar width. Public so the panel host (FacetApp's
/// PanelHost) can pick it up without redefining the number.
/// User-resizable via grip at runtime.
public let sidebarWidth: CGFloat = 248

// Row heights for the different row kinds the sidebar emits.
let headerRowH: CGFloat = 40             // workspace section heading (divider above)
let headerFirstRowH: CGFloat = 26        // first workspace: no divider, tighter top
let windowRowH: CGFloat = 28             // window row, no title (compact single line)
let windowRowTallH: CGFloat = 44         // window row with title (app + title)

// Typography.
let headerFontSize: CGFloat = 12
let activeHeaderFontSize: CGFloat = 13.5 // active workspace caption slightly bigger
let windowFontSize: CGFloat = 12

let iconSize: CGFloat = 18               // app icon square
let rowPadX: CGFloat = 12

// Pointer distance (px) required before a mouseDown becomes a drag.
// Below this, the gesture stays a click.
let dragThreshold: CGFloat = 5
