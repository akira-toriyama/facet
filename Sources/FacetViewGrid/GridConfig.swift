// User-facing configuration for the overview grid.
//
// In ws-tabs this lived inside the larger `WsTabsConfig` TOML
// loader. For facet M2 the config is a plain struct with sensible
// defaults; the Controller (step 6) wires it up from `~/.config/`
// at app start.

import CoreGraphics

public struct GridConfig: Sendable {
    /// Number of columns. Clamped 1…12 at the boundary; out-of-range
    /// reads fall back to the default rather than throwing.
    public var cols: Int
    /// Where the workspace label sits relative to its cell. Accepts
    /// the two strings ws-tabs accepted: "up" (Mission Control / TS3
    /// convention, default) or "down" (Stage Manager / dock style).
    public var labelPosition: String
    /// Label font size in points.
    public var labelSize: CGFloat

    public init(cols: Int = 4,
                labelPosition: String = "up",
                labelSize: CGFloat = 15) {
        // Clamp at construction so consumers don't repeat the check.
        self.cols = min(max(cols, 1), 12)
        self.labelPosition = (labelPosition == "down") ? "down" : "up"
        self.labelSize = max(8, min(labelSize, 32))
    }

    /// Total vertical band reserved per row for the label (font size
    /// + a small breathing pad). Pre-computed since the grid layout
    /// math reads it repeatedly.
    public var labelBandHeight: CGFloat { labelSize + 7 }

    public static let standard = GridConfig()
}
