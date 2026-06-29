// Board band geometry (t-wrd2 / W2.4) — the pure layout + cursor / wheel math the
// `BoardBand` draws and drives. Text measurement is AppKit (view-side), so the
// view measures each board caption's intrinsic width and hands the widths here;
// this file owns only the arithmetic, keeping FacetCore free of AppKit (the layer
// rule). CoreGraphics (`CGFloat`) is allowed in FacetCore.

import CoreGraphics

/// One laid-out board tab. `boardIndex` is the 0-based board this tab stands
/// for — preserved through layout so a click / wheel maps back to the right
/// board (the same index `selectedBoard` / `activeBoardSections` key on).
public struct BoardTabFrame: Equatable, Sendable {
    public let boardIndex: Int
    public let x: CGFloat
    public let width: CGFloat
    public init(boardIndex: Int, x: CGFloat, width: CGFloat) {
        self.boardIndex = boardIndex
        self.x = x
        self.width = width
    }
}

/// Lay out board tabs left→right in `available` width with `gap` between them.
/// `widths[i]` is board i's intrinsic (text + horizontal padding) width,
/// measured view-side.
///
/// - If the tabs all fit at intrinsic width (the v1 2-3 board case) that IS the
///   layout — no shrink, no shift.
/// - On overflow every tab shrinks to a UNIFORM width that fits (captions
///   tail-truncate in the view). This is the safe fallback; the rail-carousel
///   ROTATE refinement (active-centred, wheel-driven, end-peek — reusing
///   `railCarouselOffsets`) is deferred until the additive many-board feature
///   actually lands. The wheel/click board switch works in both layouts since
///   it only changes which board is active, not the frame math.
///
/// Pure / total: empty input → no frames; a single tab fills its intrinsic
/// width.
public func boardTabLayout(widths: [CGFloat], available: CGFloat, gap: CGFloat)
    -> [BoardTabFrame]
{
    let n = widths.count
    guard n > 0 else { return [] }
    let totalIntrinsic = widths.reduce(0, +) + gap * CGFloat(n - 1)
    if totalIntrinsic <= available {
        var x: CGFloat = 0
        var out: [BoardTabFrame] = []
        out.reserveCapacity(n)
        for (i, w) in widths.enumerated() {
            out.append(BoardTabFrame(boardIndex: i, x: x, width: w))
            x += w + gap
        }
        return out
    }
    // Overflow: uniform shrink so the run spans exactly `available`.
    let cellW = max(0, (available - gap * CGFloat(n - 1)) / CGFloat(n))
    return (0..<n).map { i in
        BoardTabFrame(boardIndex: i, x: (cellW + gap) * CGFloat(i), width: cellW)
    }
}

/// Step the active board cursor by `by` (a wheel notch / swipe / arrow = ±1),
/// CLAMPED to `0..<count`. A tab bar is not an infinite carousel — wheeling
/// past an end stays put (predictable), unlike the rail's circular wrap. A
/// zero / negative `count` returns 0 (defensive — the tab bar never shows
/// with < 2 boards, but the helper stays total).
public func boardIndexStep(current: Int, by: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return max(0, min(count - 1, current + by))
}

/// Convert a raw scroll-wheel `deltaY` into an integer step count for a board /
/// section switcher — the shared "precise vs notched" accumulation math the tree
/// `BoardBand`, the rail `RailBoardBand`, and the `RailView` carousel previously
/// each copied verbatim (t-9amp / R1). Pure / total; lives here so it's
/// unit-testable.
///
/// - PRECISE (trackpad / Magic Mouse): `deltaY` points accumulate into `accum`
///   (inout); every whole `threshold` of travel yields one ±1 step and is drained
///   from `accum`, so a sub-threshold remainder carries to the next call.
///   `gestureBegan` (`NSEvent.phase` `.began`) resets `accum` first so a stale
///   leftover can't bias a fresh, unrelated gesture. All drains in one call share
///   a sign (|accum| shrinks monotonically toward 0), so the NET return equals the
///   per-drain sequence — a caller wanting per-step emission just loops
///   `abs(result)` times with `result.signum()`, one wanting a single clamped
///   apply hands the net straight to `boardIndexStep`.
/// - NOTCHED (classic wheel): one detent = exactly ±1, no accumulation.
///
/// Sign: a NEGATIVE `deltaY` (content scrolled DOWN, natural-scroll sign already
/// baked into the value) → +1 ("next"); positive → -1 ("prev"). `deltaY == 0`
/// → 0. A non-positive `threshold` returns 0 (defensive — it would otherwise
/// never drain; the real call sites pass a positive constant).
public func wheelSteps(deltaY: CGFloat, accum: inout CGFloat,
                       threshold: CGFloat, precise: Bool,
                       gestureBegan: Bool) -> Int {
    guard deltaY != 0 else { return 0 }
    guard precise else { return deltaY < 0 ? 1 : -1 }
    guard threshold > 0 else { return 0 }
    if gestureBegan { accum = 0 }
    accum += deltaY
    var step = 0
    while abs(accum) >= threshold {
        let d = accum < 0 ? 1 : -1            // down → next, up → prev
        accum += CGFloat(d) * threshold
        step += d
    }
    return step
}
