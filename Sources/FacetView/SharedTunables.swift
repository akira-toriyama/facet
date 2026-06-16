// Tunables shared by every view module (tree / grid / rail). These were
// duplicated as identical per-module constants — the comments even
// admitted it ("same value as FacetViewTree's tunable — kept module-local
// to avoid a cross-module import"). Since all three view modules already
// import FacetView, the import is free, so they live here as the single
// source of truth.

import CoreGraphics
import Foundation

/// Pointer distance (px) a mouseDown must travel before it becomes a
/// drag; below this the gesture stays a click. Used by every view's
/// drag-vs-click discrimination (tree row drag, grid / rail thumb drag).
public let pointerDragThreshold: CGFloat = 5

/// Ease-out duration of the grid / rail commit "cell/hero zoom → full
/// screen" transition (Return / click on the selected cell; the backend
/// workspace switch fires as it ends).
public let overviewCommitZoomDuration: TimeInterval = 0.20
