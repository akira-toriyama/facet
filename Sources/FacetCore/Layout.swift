// Pure layout engines — the geometry half of facet's tiling.
//
// A `LayoutEngine` maps an ordered list of window ids to on-screen
// frames within a rect. It is pure: no AX, no AppKit, no per-call
// state, so same inputs → same output and every layout is unit-
// testable in FacetCore without a display or accessibility grant.
//
// Stateful layouts keep their bespoke adapter paths (bsp's split
// tree, stack's parked order live in `FacetAdapterNative`); the
// registry here is the seam new *stateless* layouts plug into —
// each is one value type conforming to `LayoutEngine` plus a
// `LayoutRegistry.all` entry. By the project's layer rules this is
// pure logic (CoreGraphics only), so it belongs in FacetCore;
// adapters call it and apply the frames through AX.

import CoreGraphics

/// Tunable knobs shared across the master layouts (`tall` / `wide` /
/// `centered`). Per-workspace runtime state (never persisted to
/// config); the adapter owns the values and passes a snapshot in on
/// each `frames` call. Engines read only the knobs they care about —
/// grid / spiral read none. The Tall-vs-Wide axis is *not* a knob: it
/// is encoded by which engine runs (`TallLayout` vs `WideLayout`),
/// swapped via `--toggle-orientation`.
public struct LayoutParams: Sendable, Equatable {
    /// Fraction of the rect the master area receives (clamped 0.05…0.95).
    public var masterRatio: CGFloat
    /// Number of windows in the master area (clamped ≥ 1).
    public var masterCount: Int

    public init(masterRatio: CGFloat = 0.5, masterCount: Int = 1) {
        self.masterRatio = max(0.05, min(0.95, masterRatio))
        self.masterCount = max(1, masterCount)
    }
}

/// A stateless tiling layout: a pure function from an ordered window
/// list to per-window frames within `rect`.
public protocol LayoutEngine: Sendable {
    /// Canonical mode name — lower-case, kebab-case if multi-word.
    /// Used by `--set-layout=NAME` and `Workspace.layoutMode`.
    var name: String { get }

    /// Map each id in `order` to a frame inside `rect`. `order` is the
    /// workspace's non-floating windows in a stable order; `focused`
    /// is the OS-focused id when known (layouts that don't care — most
    /// — ignore it).
    func frames(order: [WindowID], focused: WindowID?,
                params: LayoutParams, in rect: CGRect) -> [WindowID: CGRect]

    /// Whether this engine has a privileged *master* window
    /// (`order[0]`) — the flag behind `Window.isMaster` and the tree's
    /// `master` chip. `true` for the master-stack engines
    /// (tall / wide / centered); `false` for grid / spiral, which tile
    /// every window co-equally. Engines that keep their own stateful
    /// adapter path and aren't in `LayoutRegistry` (bsp / stack /
    /// float) report no master via the `?? false` at the call site.
    var hasMaster: Bool { get }
}

extension LayoutEngine {
    /// Default: an engine has a master unless it opts out. The master-
    /// stack engines (tall / wide / centered) inherit this; grid /
    /// spiral override to `false`.
    public var hasMaster: Bool { true }
}

/// Tall / master-stack (dwm `tile`, xmonad `Tall`, Amethyst "Tall").
/// The first `masterCount` windows fill the left master column
/// (`masterRatio` of the width) as equal-height rows; the rest stack
/// as rows in the right column. ≤ `masterCount` windows → master
/// fills the whole rect. `order[0]` is the primary master
/// (`promoteToMaster` reorders). The horizontal twin is `WideLayout`;
/// `--toggle-orientation` swaps a workspace between the two.
public struct TallLayout: LayoutEngine {
    public let name = "tall"
    public init() {}

    public func frames(order: [WindowID], focused: WindowID?,
                       params: LayoutParams,
                       in rect: CGRect) -> [WindowID: CGRect] {
        guard !order.isEmpty else { return [:] }
        var out: [WindowID: CGRect] = [:]
        let m = min(params.masterCount, order.count)
        let masters = Array(order.prefix(m))
        let stack = Array(order.dropFirst(m))
        guard !stack.isEmpty else {
            rows(masters, in: rect, into: &out); return out
        }
        let masterW = rect.width * params.masterRatio
        rows(masters,
             in: CGRect(x: rect.minX, y: rect.minY,
                        width: masterW, height: rect.height),
             into: &out)
        rows(stack,
             in: CGRect(x: rect.minX + masterW, y: rect.minY,
                        width: rect.width - masterW,
                        height: rect.height),
             into: &out)
        return out
    }

    /// Split `ids` into equal-height rows filling `rect`, first id at
    /// `minY` — matching `LayoutTree`'s horizontal-split convention.
    private func rows(_ ids: [WindowID], in rect: CGRect,
                      into out: inout [WindowID: CGRect]) {
        guard !ids.isEmpty else { return }
        let h = rect.height / CGFloat(ids.count)
        for (i, id) in ids.enumerated() {
            out[id] = CGRect(x: rect.minX,
                             y: rect.minY + CGFloat(i) * h,
                             width: rect.width, height: h)
        }
    }
}

/// Wide — `TallLayout` rotated 90°. The first `masterCount` windows
/// fill the top master row (`masterRatio` of the height) split into
/// equal-width columns; the rest fill a bottom row of columns. ≤
/// `masterCount` windows → master fills the whole rect. `order[0]` is
/// the primary master (`promoteToMaster` reorders). The vertical twin
/// is `TallLayout`; `--toggle-orientation` swaps a workspace between
/// the two.
public struct WideLayout: LayoutEngine {
    public let name = "wide"
    public init() {}

    public func frames(order: [WindowID], focused: WindowID?,
                       params: LayoutParams,
                       in rect: CGRect) -> [WindowID: CGRect] {
        guard !order.isEmpty else { return [:] }
        var out: [WindowID: CGRect] = [:]
        let m = min(params.masterCount, order.count)
        let masters = Array(order.prefix(m))
        let stack = Array(order.dropFirst(m))
        guard !stack.isEmpty else {
            cols(masters, in: rect, into: &out); return out
        }
        let masterH = rect.height * params.masterRatio
        cols(masters,
             in: CGRect(x: rect.minX, y: rect.minY,
                        width: rect.width, height: masterH),
             into: &out)
        cols(stack,
             in: CGRect(x: rect.minX, y: rect.minY + masterH,
                        width: rect.width,
                        height: rect.height - masterH),
             into: &out)
        return out
    }

    /// Split `ids` into equal-width columns filling `rect`, first id
    /// at `minX`.
    private func cols(_ ids: [WindowID], in rect: CGRect,
                      into out: inout [WindowID: CGRect]) {
        guard !ids.isEmpty else { return }
        let w = rect.width / CGFloat(ids.count)
        for (i, id) in ids.enumerated() {
            out[id] = CGRect(x: rect.minX + CGFloat(i) * w,
                             y: rect.minY,
                             width: w, height: rect.height)
        }
    }
}

/// Centered master (dwm `centeredmaster`, xmonad ThreeColMid). The
/// first `masterCount` windows fill a centered column (`masterRatio`
/// of the width) as equal-height rows; the rest split between left
/// and right side columns (right gets the extra one on an odd count).
/// With ≤ `masterCount` windows the master fills the whole rect. The
/// master stays centered even when only one side has windows — the
/// defining ultrawide look. CLI name `centered`.
public struct CenteredLayout: LayoutEngine {
    public let name = "centered"
    public init() {}

    public func frames(order: [WindowID], focused: WindowID?,
                       params: LayoutParams,
                       in rect: CGRect) -> [WindowID: CGRect] {
        guard !order.isEmpty else { return [:] }
        var out: [WindowID: CGRect] = [:]
        let m = min(params.masterCount, order.count)
        let masters = Array(order.prefix(m))
        let stack = Array(order.dropFirst(m))

        guard !stack.isEmpty else {
            rows(masters, in: rect, into: &out)
            return out
        }
        let sideW = rect.width * (1 - params.masterRatio) / 2
        let centerW = rect.width - sideW * 2
        let rightCount = (stack.count + 1) / 2     // right ≥ left
        let right = Array(stack.prefix(rightCount))
        let left = Array(stack.dropFirst(rightCount))
        rows(left,
             in: CGRect(x: rect.minX, y: rect.minY,
                        width: sideW, height: rect.height),
             into: &out)
        rows(masters,
             in: CGRect(x: rect.minX + sideW, y: rect.minY,
                        width: centerW, height: rect.height),
             into: &out)
        rows(right,
             in: CGRect(x: rect.minX + sideW + centerW, y: rect.minY,
                        width: sideW, height: rect.height),
             into: &out)
        return out
    }

    /// Equal-height rows filling `rect`, first id at `minY`.
    private func rows(_ ids: [WindowID], in rect: CGRect,
                      into out: inout [WindowID: CGRect]) {
        guard !ids.isEmpty else { return }
        let h = rect.height / CGFloat(ids.count)
        for (i, id) in ids.enumerated() {
            out[id] = CGRect(x: rect.minX,
                             y: rect.minY + CGFloat(i) * h,
                             width: rect.width, height: h)
        }
    }
}

/// Grid (awesome `grid`, Qtile `Grid`). Tiles N windows into a
/// near-square grid: `cols = ceil(√N)` columns over `ceil(N/cols)`
/// rows, filled left→right / top→bottom in `order`. The final row is
/// widened to fill the width (no trailing gap). Master knobs unused —
/// grid has no master.
public struct GridLayout: LayoutEngine {
    public let name = "grid"
    public let hasMaster = false   // co-equal grid — no master
    public init() {}

    public func frames(order: [WindowID], focused: WindowID?,
                       params: LayoutParams,
                       in rect: CGRect) -> [WindowID: CGRect] {
        let n = order.count
        guard n > 0 else { return [:] }
        // cols = ceil(√n) via integer math (no Foundation dependency).
        var cols = 1
        while cols * cols < n { cols += 1 }
        let rows = (n + cols - 1) / cols
        let cellH = rect.height / CGFloat(rows)
        var out: [WindowID: CGRect] = [:]
        for (i, id) in order.enumerated() {
            let row = i / cols
            let colInRow = i - row * cols
            // The last row may hold fewer than `cols` windows — widen
            // its cells so the row still fills the full width.
            let rowCount = (row == rows - 1) ? (n - row * cols) : cols
            let cellW = rect.width / CGFloat(rowCount)
            out[id] = CGRect(x: rect.minX + CGFloat(colInRow) * cellW,
                             y: rect.minY + CGFloat(row) * cellH,
                             width: cellW, height: cellH)
        }
        return out
    }
}

/// Spiral / Fibonacci (dwm `fibonacci`, awesome `spiral`). The first
/// window takes half the rect; each subsequent window halves the
/// *remaining* space, rotating the split clockwise (left → top →
/// right → bottom → …) so windows wind inward like a nautilus. The
/// last window fills whatever remains. Fixed 0.5 split keeps it a
/// pure function of `order` (no per-split resize — that would need
/// persisted ratios, out of scope here). Master knobs unused.
public struct SpiralLayout: LayoutEngine {
    public let name = "spiral"
    public let hasMaster = false   // fibonacci spiral — no master
    public init() {}

    public func frames(order: [WindowID], focused: WindowID?,
                       params: LayoutParams,
                       in rect: CGRect) -> [WindowID: CGRect] {
        guard !order.isEmpty else { return [:] }
        var out: [WindowID: CGRect] = [:]
        var r = rect
        let last = order.count - 1
        for (i, id) in order.enumerated() {
            if i == last { out[id] = r; break }
            switch i % 4 {
            case 0:                                   // window left
                let w = r.width / 2
                out[id] = CGRect(x: r.minX, y: r.minY,
                                 width: w, height: r.height)
                r = CGRect(x: r.minX + w, y: r.minY,
                           width: r.width - w, height: r.height)
            case 1:                                   // window top
                let h = r.height / 2
                out[id] = CGRect(x: r.minX, y: r.minY,
                                 width: r.width, height: h)
                r = CGRect(x: r.minX, y: r.minY + h,
                           width: r.width, height: r.height - h)
            case 2:                                   // window right
                let w = r.width / 2
                out[id] = CGRect(x: r.minX + w, y: r.minY,
                                 width: r.width - w, height: r.height)
                r = CGRect(x: r.minX, y: r.minY,
                           width: w, height: r.height)
            default:                                  // window bottom
                let h = r.height / 2
                out[id] = CGRect(x: r.minX, y: r.minY + h,
                                 width: r.width, height: r.height - h)
                r = CGRect(x: r.minX, y: r.minY,
                           width: r.width, height: h)
            }
        }
        return out
    }
}

/// Registry of stateless layout engines, keyed by `name`. bsp and
/// stack are intentionally absent — they keep their stateful adapter
/// paths; this is the seam stateless layouts register into, so adding
/// one is a value type plus a line in `all`.
public enum LayoutRegistry {
    public static let all: [any LayoutEngine] = [
        TallLayout(),
        WideLayout(),
        CenteredLayout(),
        GridLayout(),
        SpiralLayout(),
    ]

    /// Mode name → engine, or nil when `name` isn't a registered
    /// stateless engine (e.g. "bsp" / "stack" / "float"). Case-
    /// insensitive to match the CLI's canonicalisation.
    public static func engine(named name: String) -> (any LayoutEngine)? {
        let key = name.lowercased()
        return all.first { $0.name == key }
    }

    /// Advertised stateless-engine names — joins bsp/stack in the
    /// backend's `layoutModes` and the CLI's accepted layout set.
    public static var names: [String] { all.map(\.name) }
}

/// Apply an inner gap to a computed frame map: shrink each frame by
/// `gap`/2 on every edge that is *interior* to `rect`, leaving any
/// edge flush with `rect`'s outer boundary untouched. Two abutting
/// windows each give up `gap`/2 on their shared edge → they end up
/// `gap` apart; a window touching the screen edge keeps that edge
/// flush, so the edge distance stays whatever the caller already
/// inset `rect` by (the outer gap). This keeps "screen-edge = outer,
/// window-gap = inner" exact rather than doubling at the border.
///
/// Assumes the layout tiled `rect` edge-to-edge (every engine here
/// does), so "flush with the boundary" is detected by comparing each
/// frame edge to the matching `rect` edge within `eps`. `gap <= 0` is
/// a no-op. Pure (CoreGraphics only) — unit-testable without a
/// display, and shared by the bsp tree path and the stateless engines.
public func applyInnerGap(_ frames: [WindowID: CGRect],
                          in rect: CGRect,
                          gap: CGFloat,
                          eps: CGFloat = 0.5) -> [WindowID: CGRect] {
    guard gap > 0 else { return frames }
    let h = gap / 2
    var out: [WindowID: CGRect] = [:]
    out.reserveCapacity(frames.count)
    for (id, f) in frames {
        var x = f.minX, y = f.minY, w = f.width, ht = f.height
        if f.minX > rect.minX + eps { x += h; w -= h }   // left has a neighbour
        if f.maxX < rect.maxX - eps { w -= h }            // right has a neighbour
        if f.minY > rect.minY + eps { y += h; ht -= h }   // bottom has a neighbour
        if f.maxY < rect.maxY - eps { ht -= h }           // top has a neighbour
        out[id] = CGRect(x: x, y: y,
                         width: max(0, w), height: max(0, ht))
    }
    return out
}

public extension CGRect {
    /// Snap every edge to a whole physical pixel for the given
    /// backing `scale` (`(v*scale).rounded()/scale`), so window
    /// edges stay crisp on HiDPI displays instead of landing on a
    /// fractional point and getting blurred / leaving a 1px seam.
    ///
    /// Rounds the leading edge (`minX`/`minY`) and the trailing edge
    /// (`maxX`/`maxY`) *independently*, then derives width/height
    /// from the difference — NOT by rounding width/height directly.
    /// That way two frames sharing an edge (one's `maxX` == the
    /// other's `minX`) round to the same value and still meet
    /// exactly. `scale <= 0` is a no-op.
    func roundedToPhysicalPixels(scale: CGFloat) -> CGRect {
        guard scale > 0 else { return self }
        let x0 = (minX * scale).rounded() / scale
        let y0 = (minY * scale).rounded() / scale
        let x1 = (maxX * scale).rounded() / scale
        let y1 = (maxY * scale).rounded() / scale
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
