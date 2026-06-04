// Pure geometry for directional window focus / move (② — yabai-style
// north/east/south/west). Given the focused window's frame and its
// siblings' frames, pick the nearest neighbour on a given side. No
// AppKit / AX here — the adapter supplies the frames and does the
// focus / swap; this stays pure so it's unit-testable without a display.
//
// Frames are AX-style screen coords (y increases DOWNWARD), so "north"
// = a smaller y. If a future backend ever feeds y-up frames, this one
// mapping (in `nearestWindow`) is where the flip would live.

import CoreGraphics

/// One of the four cardinal directions a focus / move steps toward.
/// Raw values match the CLI tokens (`window --focus=north` …).
public enum CardinalDirection: String, Sendable, Equatable, CaseIterable {
    case north, east, south, west
}

/// The sibling nearest to `focused` in `direction`, or `nil` when none
/// lies that way (an edge — the caller no-ops, matching yabai). A
/// candidate qualifies only if its centre is past the focused centre
/// ALONG that axis; among those the smallest along-axis distance wins,
/// with the perpendicular offset as a soft penalty so a squarely-aligned
/// neighbour beats a diagonal one. Pure / unit-testable.
public func nearestWindow(
    to focused: CGRect,
    among others: [(id: WindowID, frame: CGRect)],
    direction: CardinalDirection
) -> WindowID? {
    let fx = focused.midX, fy = focused.midY
    var best: (id: WindowID, score: CGFloat)?
    for o in others {
        let dx = o.frame.midX - fx
        let dy = o.frame.midY - fy
        let along: CGFloat
        let perp: CGFloat
        switch direction {
        case .north: along = -dy; perp = abs(dx)   // up = smaller y
        case .south: along =  dy; perp = abs(dx)
        case .west:  along = -dx; perp = abs(dy)
        case .east:  along =  dx; perp = abs(dy)
        }
        guard along > 0.5 else { continue }        // not on this side
        let score = along + perp * 2               // closer + aligned wins
        if best == nil || score < best!.score { best = (o.id, score) }
    }
    return best?.id
}
