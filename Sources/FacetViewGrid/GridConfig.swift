// User-facing configuration for the overview grid. Plain struct
// with sensible defaults; the Controller wires it up from
// `~/.config/facet/config.toml` at app start.

import CoreGraphics

public struct GridConfig: Sendable {
    /// Number of columns. Clamped 1…12 at the boundary; out-of-range
    /// reads fall back to the default rather than throwing.
    public var cols: Int
    /// Where the workspace header sits relative to its cell. Accepts
    /// two strings: "up" (Mission Control convention, default) or
    /// "down" (Stage Manager / dock style).
    public var labelPosition: String

    public init(cols: Int = 4,
                labelPosition: String = "up") {
        // Clamp at construction so consumers don't repeat the check.
        self.cols = min(max(cols, 1), 12)
        self.labelPosition = (labelPosition == "down") ? "down" : "up"
    }

    public static let standard = GridConfig()
}
