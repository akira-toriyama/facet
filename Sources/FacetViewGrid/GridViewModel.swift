// The single @Observable box the SwiftUI grid binds to — the grid twin of the
// tree's `TreeViewModel`. The Controller owns it: feeds the snapshot
// (`apply`), repoints `palette` on theme ticks, drives every keyboard verb
// through the local monitor (the tree's load-bearing invariant: sill's own
// key handling never engages — the host monitor swallows the keys first),
// and reads the reported cell geometry back for menus / zoom / hit tests.
//
// DnD split (mirrors the tree): sill's `ThemedGridView` owns the POINTER
// cell-reorder turnkey (drag a header/cell → insertion line → `onGridDrop`);
// the host owns the two facet-specific gestures sill has no cell-level model
// for — the window-thumb MOVE (a drag of a subview inside the cell content)
// and the keyboard workspace SWAP — and renders both through the kit's
// `GridPreview` seam so the affordances (target ring, source dim, ghost)
// stay sill-standard.

import AppKit
import CoreGraphics
import Foundation
import Observation
import FacetCore
import FacetView
import PaletteKit
import Effects
import ThemeKitUI

// MARK: - View-facing value types

/// One window thumb inside a cell's mini-screen, its rect NORMALIZED to the
/// unit square (the mini-screen scales it at render time, so layout math
/// stays pure and size-independent).
public struct GridThumbVM: Identifiable, Equatable {
    public let id: WindowID
    public let pid: Int
    public let isFocused: Bool
    public let norm: CGRect
    public let mark: String?
}

/// One rendered cell — the projected section (workspace / lens) plus its
/// pre-scaled thumbs. `kbOrder` maps reading-order slots (Tab cycling) to
/// `thumbs` indices; `thumbs` itself stays in z-order (draw order).
public struct GridCellVM: Identifiable {
    public let id: String            // sectionID ("ws:<i>" / "section:…")
    public let wsIndex: Int          // 0-based source WS; -1 for a lens cell
    public let sectionType: ProjectedSectionType
    public let caption: String       // §D `index (label)`
    public let mode: String          // layout engine ("" = none)
    public let isActive: Bool
    public let thumbs: [GridThumbVM]
    public let kbOrder: [Int]
}

@MainActor
@Observable
public final class GridViewModel {

    // MARK: Inputs (Controller-supplied)

    /// Per-surface palette (`[grid].theme`). The Controller repoints this on
    /// both theme paths (hot-reload + the 30 Hz animator tick); a palette-only
    /// write must leave `cells` untouched so re-colouring never re-layouts.
    public var palette: ResolvedPalette
    /// Layout / typography config, set at show time (`[grid]` table).
    public var config: GridConfig = .standard
    /// Display frame the windows were measured against; thumb rects scale
    /// from it (snapshot-on-show, like the old view).
    public var screenFrame: CGRect = .zero

    // MARK: Callbacks (Controller-wired; same meanings as the old GridView)

    public var onDismiss: (() -> Void)?
    public var onPick: ((GridPick) -> Void)?
    public var onMoveWindow: ((_ src: Int, _ dst: Int,
                               _ pid: Int, _ id: WindowID) -> Void)?
    public var onSwap: ((_ srcWS: Int, _ dstWS: Int,
                         _ srcIDs: [WindowID], _ dstIDs: [WindowID]) -> Void)?
    public var onReorder: ((_ sectionID: String, _ toBoundary: Int) -> Void)?

    // MARK: Snapshot + derived cells

    public private(set) var cells: [GridCellVM] = []
    /// Bumped whenever the cell SCAFFOLD changes (sections added / reordered /
    /// re-sized inputs) — the SwiftUI cells key their identity on it, so a
    /// structural re-layout SNAPS thumbs instead of FLIP-sliding them (the
    /// t-3q17 rule, expressed as view identity instead of rect bookkeeping).
    public private(set) var structuralEpoch = 0
    private var workspaces: [Workspace] = []
    private var sections: [ProjectedSection] = []
    /// Window id → home workspace index (0-based), rebuilt each apply from the
    /// unfiltered snapshot. Picks resolve a thumb's home WS through this,
    /// never through the cell's `wsIndex` (a lens cell reports −1).
    public private(set) var windowHomeWS: [WindowID: Int] = [:]

    // MARK: Thumbnails (Controller-fed, progressive)

    public private(set) var thumbnails: [WindowID: NSImage] = [:]

    // MARK: Keyboard cursor (host-driven; sill renders it via the selection
    // binding — the kit's own focus/cursor never engage)

    public private(set) var kbCursorID: String?
    /// Window cursor within the cursor cell: `-1` = the header slot (no
    /// window ring), `0…n-1` = a reading-order slot (Tab picks a window).
    public private(set) var kbWindowIdx: Int = -1

    // MARK: Host drag (window move + keyboard workspace swap)

    enum HostDragKind: Equatable {
        case window(pid: Int, id: WindowID, sourceWS: Int,
                    sourceCellID: String, thumbSize: CGSize)
        case workspaceSwap(sourceCellID: String, sourceWS: Int)
    }
    struct HostDrag {
        var kind: HostDragKind
        var location: CGPoint            // grid-content coords (ghost anchor)
        var targetCellID: String?
        var isKeyboard: Bool
    }
    private(set) var drag: HostDrag?
    /// The dragged thumb stays hidden through the drag AND the landing gate
    /// (the ghost stands in) — cleared when the backend acks.
    private(set) var hiddenThumbID: WindowID?

    /// Landing gates (FacetCore, shared with the rail): the drag visuals
    /// persist until the backend reflects the move/swap, so a refresh racing
    /// the round-trip can't paint an afterimage.
    private var lastDrop: OverviewPendingDrop?
    private var lastSwap: OverviewPendingSwap?

    // MARK: Refresh suppression (the old `layoutSuppressed`)

    /// True while any pointer button is down inside the overlay (the monitor
    /// maintains it). Covers the kit's own reorder drag too — the kit keeps
    /// its drag state private, but a pressed button is observable.
    public var pointerBusy = false { didSet { if !pointerBusy { flushPending() } } }
    private var pendingApply: (wss: [Workspace], secs: [ProjectedSection])?

    // MARK: Geometry (view-reported, grid-content coordinate space)

    public internal(set) var cellFrames: [String: CGRect] = [:]
    public internal(set) var miniFrames: [String: CGRect] = [:]
    public internal(set) var headerFrames: [String: CGRect] = [:]

    // MARK: Commit zoom (②)

    struct ZoomPose { let image: NSImage; let from: CGRect }
    private(set) var zoom: ZoomPose?
    var zoomExpanded = false
    private var zoomPerform: (() -> Void)?
    /// Captures a region of the live rendering (the Controller wires the
    /// hosting view's `snapshotRegion`).
    public var snapshotProvider: ((CGRect) -> NSImage?)?
    /// Injectable for tests; defaults to the live accessibility setting.
    public var reduceMotionCheck: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: Border (`[border]` — rendered by sill's AnimatedBorderView)

    public private(set) var borderEffect: EffectSpec?
    public private(set) var borderGlow = false
    public private(set) var borderLineWidth: CGFloat = 1.5
    public private(set) var borderBreathTo: CGFloat = 1.5
    public private(set) var borderCycleSeconds: Double = 6
    public private(set) var borderCyclesColors = false
    public private(set) var borderFlashToken = 0

    public init(palette: ResolvedPalette) {
        self.palette = palette
    }

    // MARK: - Snapshot application (landing gates + suppression, the old
    // `layoutCells` gate order)

    /// True while a gesture must keep the scaffold frozen: a live drag the
    /// host knows about, or any pressed pointer (covers the kit's internal
    /// reorder drag). A COMMITTED drag (landing gate armed) is not "live" —
    /// the gate below owns that phase.
    private var suppressed: Bool {
        if pointerBusy { return true }
        if drag != nil, lastDrop == nil, lastSwap == nil { return true }
        return false
    }

    public func apply(workspaces wss: [Workspace],
                      sections secs: [ProjectedSection]) {
        if suppressed { pendingApply = (wss, secs); return }
        var droppedLanded = false
        if let ld = lastDrop {
            if ld.landed(in: wss) {
                droppedLanded = true
            } else if Date().timeIntervalSince(ld.committedAt) > overviewDropAckTimeout {
                lastDrop = nil; drag = nil; hiddenThumbID = nil   // give up, reveal
            } else {
                pendingApply = (wss, secs); return
            }
        }
        var swapLanded = false
        if let ls = lastSwap {
            if ls.landed(in: wss) {
                swapLanded = true
            } else if Date().timeIntervalSince(ls.committedAt) > overviewDropAckTimeout {
                lastSwap = nil; drag = nil
            } else {
                pendingApply = (wss, secs); return
            }
        }
        pendingApply = nil
        workspaces = wss
        sections = secs
        rebuild()
        if droppedLanded {
            lastDrop = nil; drag = nil; hiddenThumbID = nil
        }
        if swapLanded {
            // Every thumb changed cells — identity-keyed views already snap
            // (remove+insert), and the epoch bump snaps any same-cell rect too.
            lastSwap = nil; drag = nil
            structuralEpoch += 1
        }
    }

    private func flushPending() {
        guard let p = pendingApply, !suppressed else { return }
        pendingApply = nil
        apply(workspaces: p.wss, sections: p.secs)
    }

    /// EX-2: one render source per cell — projected sections (workspace +
    /// lens) when the section model is active, else one per workspace
    /// (byte-identical degrade). The §D caption composes here.
    private func rebuild() {
        windowHomeWS = [:]
        for ws in workspaces { for w in ws.windows { windowHomeWS[w.id] = ws.index } }

        struct Source {
            let wsIndex: Int
            let sectionType: ProjectedSectionType
            let sectionID: String
            let label: String
            let mode: String
            let windows: [Window]
            let isActive: Bool
        }
        let sources: [Source]
        if sections.isEmpty {
            sources = workspaces.enumerated().map { (i, ws) in
                Source(wsIndex: ws.index, sectionType: .workspace,
                       sectionID: "ws:\(ws.index)",
                       label: sectionDisplayLabel(index: i + 1, label: ws.name),
                       mode: ws.layoutMode, windows: ws.windows,
                       isActive: ws.isActive)
            }
        } else {
            sources = sections.enumerated().map { (i, sec) in
                let srcWS = sec.sourceWorkspaceIndex.flatMap { src in
                    workspaces.first { $0.index == src } }
                let mode: String
                let active: Bool
                switch sec.sectionType {
                case .workspace:
                    mode = srcWS?.layoutMode ?? ""
                    active = srcWS?.isActive == true
                case .matched, .holding:
                    // An isolate desktop is TREE-ONLY; nothing mints these for
                    // the grid — but the switch stays exhaustive (t-pvay).
                    mode = ""
                    active = false
                }
                return Source(wsIndex: sec.sourceWorkspaceIndex ?? -1,
                              sectionType: sec.sectionType, sectionID: sec.id,
                              label: sectionDisplayLabel(index: i + 1, label: sec.label),
                              mode: mode, windows: sec.windows, isActive: active)
            }
        }

        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let newCells: [GridCellVM] = sources.map { src in
            var thumbs: [GridThumbVM] = []
            if screenFrame.width > 0 {
                for win in src.windows {
                    guard let f = win.frame else { continue }
                    let n = gridScaledWindowRect(windowFrame: f,
                                                 screenFrame: screenFrame,
                                                 cellRect: unit)
                    guard n.width > 0, n.height > 0 else { continue }
                    thumbs.append(GridThumbVM(id: win.id, pid: win.pid,
                                              isFocused: win.isFocused,
                                              norm: n, mark: win.mark))
                }
            }
            // Reading order needs REAL distances: `readingOrder`'s row band
            // is `max(1, maxHeight/2)`, which in unit space floors at the
            // whole square and collapses every row into one x-sort (the
            // earlier "anisotropic scale preserves it" claim was wrong —
            // measured, rail adversarial review 2026-08-25). Scale the hits
            // back to screen size first.
            let sw = max(screenFrame.width, 1)
            let sh = max(screenFrame.height, 1)
            let hits = thumbs.map {
                MiniWindowHit(pid: $0.pid, id: $0.id, isFocused: $0.isFocused,
                              rect: CGRect(x: $0.norm.minX * sw,
                                           y: $0.norm.minY * sh,
                                           width: $0.norm.width * sw,
                                           height: $0.norm.height * sh),
                              mark: $0.mark)
            }
            let ordered = readingOrder(hits)
            let kbOrder = ordered.compactMap { o in thumbs.firstIndex { $0.id == o.id } }
            return GridCellVM(id: src.sectionID, wsIndex: src.wsIndex,
                              sectionType: src.sectionType, caption: src.label,
                              mode: src.mode, isActive: src.isActive,
                              thumbs: thumbs, kbOrder: kbOrder)
        }

        if newCells.map(\.id) != cells.map(\.id) { structuralEpoch += 1 }
        cells = newCells
        // The cursor survives a refresh when its cell does; a vanished cell
        // reseeds to the active cell so keyboard nav never dies mid-show.
        if let c = kbCursorID, !cells.contains(where: { $0.id == c }) {
            kbSeedToActiveCell()
        }
        if let ds = drag, !cells.contains(where: { $0.id == sourceCellID(of: ds) }) {
            cancelDrag()
        }
    }

    private func sourceCellID(of d: HostDrag) -> String {
        switch d.kind {
        case .window(_, _, _, let cell, _): return cell
        case .workspaceSwap(let cell, _):   return cell
        }
    }

    // MARK: - Thumbnails

    public func setThumbnail(_ image: NSImage, for id: WindowID) {
        thumbnails[id] = image
    }

    public func clearThumbnails() {
        thumbnails.removeAll()
    }

    // MARK: - Keyboard (host monitor → these verbs; sill never sees the keys)

    public var effectiveCols: Int { max(1, min(config.cols, max(cells.count, 1))) }

    private var cursorCell: GridCellVM? {
        kbCursorID.flatMap { id in cells.first { $0.id == id } }
    }

    /// The cell the keyboard cursor sits on — the `m`-menu + host anchors
    /// read it (the internal resolver, published).
    public var kbCursorCell: GridCellVM? { cursorCell }

    /// The reading-order slot the window cursor points at, resolved to the
    /// z-order thumb (draw index) the ring wraps.
    public var kbSelectedThumb: (cell: GridCellVM, thumb: GridThumbVM, thumbIndex: Int)? {
        guard kbWindowIdx >= 0, let cell = cursorCell, !cell.thumbs.isEmpty
        else { return nil }
        let slot = max(0, min(cell.kbOrder.count - 1, kbWindowIdx))
        let ti = cell.kbOrder[slot]
        return (cell, cell.thumbs[ti], ti)
    }

    public func kbSeedToActiveCell() {
        kbCursorID = (cells.first(where: { $0.isActive }) ?? cells.first)?.id
        kbWindowIdx = -1
    }

    public func kbMove(dx: Int, dy: Int) {
        guard zoom == nil else { return }
        guard let sel = kbCursorID,
              let cur = cells.firstIndex(where: { $0.id == sel })
        else { kbSeedToActiveCell(); return }
        let ni = gridWrapIndex(index: cur, dx: dx, dy: dy,
                               cols: effectiveCols, count: cells.count)
        guard ni < cells.count else { return }
        kbCursorID = cells[ni].id
        kbWindowIdx = -1
        if drag != nil { syncKbDragToCursor() }
    }

    public func kbCycleWindow(forward: Bool) {
        guard zoom == nil, drag == nil, let cell = cursorCell else { return }
        kbWindowIdx = cycleSlotIndex(current: kbWindowIdx,
                                     windowCount: cell.thumbs.count,
                                     forward: forward)
    }

    /// Space is a TOGGLE (matches the tree): carrying → drop (= Return),
    /// otherwise lift whatever the cursor points at (window / whole WS).
    public func kbSpaceLift() {
        guard zoom == nil else { return }
        if drag != nil { kbCommit(); return }
        if kbWindowIdx == -1 { kbLiftWorkspace() } else { kbLift() }
    }

    /// Lift the keyboard-selected window for a move. Workspace cells only —
    /// a lens cell's thumb has no source workspace to move from. Refused while
    /// a pointer button is down: the kit's own reorder drag may be live then
    /// (its state is private), and a second, host drag would fight it.
    public func kbLift() {
        guard zoom == nil, drag == nil, !pointerBusy, let s = kbSelectedThumb,
              s.cell.sectionType == .workspace else { return }
        let size = thumbAbsRect(cellID: s.cell.id, thumbIndex: s.thumbIndex)?.size
            ?? CGSize(width: 96, height: 64)
        drag = HostDrag(
            kind: .window(pid: s.thumb.pid, id: s.thumb.id,
                          sourceWS: s.cell.wsIndex,
                          sourceCellID: s.cell.id, thumbSize: size),
            location: cellAnchor(s.cell.id),
            targetCellID: nil,
            isKeyboard: true)
        hiddenThumbID = s.thumb.id
    }

    /// Lift the cursor cell's WHOLE contents for a workspace swap (header
    /// slot). Arrows then re-aim, Return commits. An empty source can still
    /// lift ("move WS-X's contents here, leaving X empty in return").
    public func kbLiftWorkspace() {
        guard zoom == nil, drag == nil, !pointerBusy, let cell = cursorCell,
              cell.sectionType == .workspace else { return }
        drag = HostDrag(
            kind: .workspaceSwap(sourceCellID: cell.id, sourceWS: cell.wsIndex),
            location: cellAnchor(cell.id),
            targetCellID: nil,
            isKeyboard: true)
    }

    /// While lifted via keyboard, the cursor IS the drop target — valid only
    /// on a workspace cell that isn't the source (EX-2 MUST-FIX #2).
    private func syncKbDragToCursor() {
        guard var d = drag, let cell = cursorCell else { return }
        let srcWS: Int
        switch d.kind {
        case .window(_, _, let s, _, _):  srcWS = s
        case .workspaceSwap(_, let s):    srcWS = s
        }
        d.targetCellID = (cell.sectionType != .workspace || cell.wsIndex == srcWS)
            ? nil : cell.id
        d.location = cellAnchor(cell.id)
        drag = d
    }

    /// Return: commit-drop while lifted, or click-equivalent when not —
    /// the cell zooms out to full screen (②), then the switch + close fire.
    public func kbCommit() {
        guard zoom == nil else { return }
        if let d = drag {
            if let tid = d.targetCellID, let dst = cells.first(where: { $0.id == tid }) {
                switch d.kind {
                case .window(let pid, let id, let srcWS, _, _):
                    commitWindowDrop(pid: pid, id: id, sourceWS: srcWS, dstCell: dst)
                case .workspaceSwap(let srcCellID, let srcWS):
                    commitSwap(sourceCellID: srcCellID, sourceWS: srcWS, dstCell: dst)
                }
            } else {
                cancelDrag()
            }
            return
        }
        guard let cell = cursorCell else { return }
        if let s = kbSelectedThumb {
            commitSwitch(target: cell.id) { [weak self] in
                self?.onPick?(.window(
                    homeWorkspaceIndex: self?.windowHomeWS[s.thumb.id] ?? cell.wsIndex,
                    pid: s.thumb.pid, windowID: s.thumb.id))
            }
        } else {
            commitSwitch(target: cell.id) { [weak self] in
                self?.onPick?(.workspace(workspaceIndex: cell.wsIndex))
            }
        }
    }

    /// Esc, in order: cancel an in-flight lift → clear a Tab window
    /// selection (stay open) → dismiss the grid.
    public func kbEscape() {
        if drag != nil {
            cancelDrag()
        } else if kbWindowIdx != -1 {
            kbWindowIdx = -1
        } else {
            onDismiss?()
        }
    }

    // MARK: - Pointer picks (cell content gestures; the kit's own tap never
    // fires — the inner gesture wins, so sill's focus ring stays out too)

    public func tapBackdrop() {
        guard zoom == nil else { return }
        onDismiss?()
    }

    public func tapCell(_ cellID: String) {
        guard zoom == nil, drag == nil else { return }
        guard let cell = cells.first(where: { $0.id == cellID }) else { return }
        onPick?(.workspace(workspaceIndex: cell.wsIndex))
    }

    public func tapThumb(cellID: String, thumb: GridThumbVM) {
        guard zoom == nil, drag == nil else { return }
        guard let cell = cells.first(where: { $0.id == cellID }) else { return }
        onPick?(.window(homeWorkspaceIndex: windowHomeWS[thumb.id] ?? cell.wsIndex,
                        pid: thumb.pid, windowID: thumb.id))
    }

    // MARK: - Pointer thumb drag (host gesture — the one drag sill's
    // cell-level model can't see)

    public func thumbDragChanged(cellID: String, thumb: GridThumbVM,
                                 thumbIndex: Int, location: CGPoint) {
        guard zoom == nil else { return }
        if drag == nil {
            guard let cell = cells.first(where: { $0.id == cellID }) else { return }
            // A lens cell's thumb still drags — its source is the window's
            // HOME WS (resolved), the old mouseDown rule. Only the KEYBOARD
            // lift is workspace-cell-only.
            let size = thumbAbsRect(cellID: cellID, thumbIndex: thumbIndex)?.size
                ?? CGSize(width: 96, height: 64)
            drag = HostDrag(
                kind: .window(pid: thumb.pid, id: thumb.id,
                              sourceWS: windowHomeWS[thumb.id] ?? cell.wsIndex,
                              sourceCellID: cellID, thumbSize: size),
                location: location, targetCellID: nil, isKeyboard: false)
            hiddenThumbID = thumb.id
        }
        guard var d = drag, !d.isKeyboard else { return }
        d.location = location
        d.targetCellID = moveTarget(at: location, excludingWS: sourceWS(of: d))
        drag = d
    }

    public func thumbDragEnded() {
        guard let d = drag, !d.isKeyboard else { return }
        if let tid = d.targetCellID, let dst = cells.first(where: { $0.id == tid }),
           case .window(let pid, let id, let srcWS, _, _) = d.kind {
            commitWindowDrop(pid: pid, id: id, sourceWS: srcWS, dstCell: dst)
        } else {
            cancelDrag()
        }
    }

    private func sourceWS(of d: HostDrag) -> Int {
        switch d.kind {
        case .window(_, _, let s, _, _): return s
        case .workspaceSwap(_, let s):   return s
        }
    }

    /// The workspace cell (≠ source) under `point` — a window move's only
    /// valid landing. A lens cell is never a move target (no source WS).
    private func moveTarget(at point: CGPoint, excludingWS: Int) -> String? {
        for cell in cells {
            guard cell.sectionType == .workspace, cell.wsIndex != excludingWS
            else { continue }
            if cellFrames[cell.id]?.contains(point) == true
                || headerFrames[cell.id]?.contains(point) == true {
                return cell.id
            }
        }
        return nil
    }

    // MARK: - Commits (landing-gated, the old `commitDrop` /
    // `commitContentSwap` shapes)

    private func commitWindowDrop(pid: Int, id: WindowID, sourceWS: Int,
                                  dstCell: GridCellVM) {
        lastDrop = OverviewPendingDrop(id: id, dstWS: dstCell.wsIndex,
                                       committedAt: Date())
        // `drag` + `hiddenThumbID` stay set: the ghost stands in for the thumb
        // until the backend acks (cleared in `apply`'s landed path).
        onMoveWindow?(sourceWS, dstCell.wsIndex, pid, id)
    }

    private func commitSwap(sourceCellID: String, sourceWS: Int,
                            dstCell: GridCellVM) {
        // Derive BOTH swap sets at COMMIT time (one epoch) from the frozen
        // cells, so a mid-drag toggle can't desync the halves.
        let srcIDs = cells.first(where: { $0.id == sourceCellID })?
            .thumbs.map(\.id) ?? []
        let dstIDs = dstCell.thumbs.map(\.id)
        if srcIDs.isEmpty && dstIDs.isEmpty {
            cancelDrag()
            return
        }
        lastSwap = OverviewPendingSwap(srcWS: sourceWS, dstWS: dstCell.wsIndex,
                                       srcIDs: srcIDs, dstIDs: dstIDs,
                                       committedAt: Date())
        onSwap?(sourceWS, dstCell.wsIndex, srcIDs, dstIDs)
    }

    public func cancelDrag() {
        drag = nil
        hiddenThumbID = nil
        lastSwap = nil
        flushPending()
    }

    /// The kit's pointer reorder landed: `boundary` is the insertion index in
    /// the projected section order (cells order — the same coords the
    /// Controller's `reorderSection` expects). Display-only, no gate.
    /// Refused while a HOST drag is live: the preview seam owns the display
    /// then, so the kit's own drag ran with zero affordances — committing it
    /// would reorder sections with no visual feedback at all.
    public func commitReorder(sectionID: String, toBoundary boundary: Int) {
        guard drag == nil else { return }
        onReorder?(sectionID, boundary)
    }

    /// Backstop for a pointer drag whose SwiftUI gesture died without an
    /// `onEnded` (the mouse monitor always sees the up event; the gesture may
    /// not — e.g. a mid-drag view rebuild). Commits or cancels at the current
    /// target, exactly like `thumbDragEnded`. A keyboard lift is untouched
    /// (it ends by key, not by button).
    public func pointerDragEndFallback() {
        // A committed drop keeps `drag` armed through the landing gate (the
        // ghost stands in), so this post-up fallback would re-run the commit
        // and fire a SECOND backend move (measured, rail adversarial review
        // 2026-08-25 — the "healthy path has already cleared `drag`" comment
        // this replaced was wrong). An armed gate IS the healthy signal.
        guard lastDrop == nil, lastSwap == nil else { return }
        guard let d = drag, !d.isKeyboard else { return }
        thumbDragEnded()
    }

    // MARK: - sill preview seam (kb drag + window drag render through it)

    /// The frozen pose sill renders while a HOST drag is live — the target
    /// ring / source dim / parked ghost come from the kit, so the affordances
    /// stay sill-standard. `nil` outside host drags (live hover + the kit's
    /// own pointer reorder).
    public var kitPreview: GridPreview<String>? {
        guard let d = drag else { return nil }
        var p = GridPreview<String>(hovered: nil, cursor: nil, focused: false)
        p.dropTargetID = d.targetCellID
        if case .workspaceSwap(let src, _) = d.kind { p.dragSource = src }
        return p
    }

    /// The host ghost card for a WINDOW drag (the kit's cell ghost covers the
    /// swap). Content mirrors the thumb: capture > app icon > blank.
    public var windowGhost: (image: NSImage?, size: CGSize, location: CGPoint)? {
        guard let d = drag, case .window(let pid, let id, _, _, let size) = d.kind
        else { return nil }
        let img = thumbnails[id] ?? AppIcons.icon(forPID: pid)
        return (image: img, size: size, location: d.location)
    }

    // MARK: - Geometry helpers (menus / zoom / hit tests read these)

    public func thumbAbsRect(cellID: String, thumbIndex: Int) -> CGRect? {
        guard let mini = miniFrames[cellID],
              let cell = cells.first(where: { $0.id == cellID }),
              cell.thumbs.indices.contains(thumbIndex) else { return nil }
        let n = cell.thumbs[thumbIndex].norm
        return CGRect(x: mini.minX + n.minX * mini.width,
                      y: mini.minY + n.minY * mini.height,
                      width: n.width * mini.width,
                      height: n.height * mini.height)
    }

    private func cellAnchor(_ cellID: String) -> CGPoint {
        guard let f = cellFrames[cellID] else { return .zero }
        return CGPoint(x: f.midX, y: f.midY)
    }

    /// The cell whose body or header contains `point` (hit order mirrors the
    /// old view: headers count as their cell).
    public func cellAt(point: CGPoint) -> GridCellVM? {
        cells.first { cell in
            cellFrames[cell.id]?.contains(point) == true
                || headerFrames[cell.id]?.contains(point) == true
        }
    }

    /// The cell whose HEADER band contains `point`.
    public func headerCellAt(point: CGPoint) -> GridCellVM? {
        cells.first { headerFrames[$0.id]?.contains(point) == true }
    }

    /// The topmost thumb under `point` (z-order: later thumbs draw last, win).
    public func thumbAt(point: CGPoint) -> (cell: GridCellVM, thumb: GridThumbVM, thumbIndex: Int)? {
        for cell in cells {
            guard let mini = miniFrames[cell.id], mini.contains(point) else { continue }
            for ti in cell.thumbs.indices.reversed() {
                if thumbAbsRect(cellID: cell.id, thumbIndex: ti)?.contains(point) == true {
                    return (cell, cell.thumbs[ti], ti)
                }
            }
        }
        return nil
    }

    // MARK: - Commit zoom (②)

    /// Play the "cell zoom → full screen" transition for `target`, then run
    /// `perform` (the switch + close). Skips straight to `perform` under
    /// Reduce Motion or when the cell can't be captured.
    public func commitSwitch(target cellID: String, perform: @escaping () -> Void) {
        guard zoom == nil else { return }
        guard !reduceMotionCheck(),
              let f = cellFrames[cellID],
              let img = snapshotProvider?(f)
        else { perform(); return }
        zoomPerform = perform
        zoomExpanded = false
        zoom = ZoomPose(image: img, from: f)
    }

    /// Fire the pending switch exactly once — the animation's completion, or
    /// the Controller's teardown path (closed mid-zoom must not drop it).
    public func finishZoom() {
        let p = zoomPerform
        zoomPerform = nil
        zoom = nil
        zoomExpanded = false
        p?()
    }

    /// Teardown backstop: only fires if a zoom is actually pending.
    public func finishZoomIfPending() {
        if zoomPerform != nil { finishZoom() }
    }

    // MARK: - Border ([border] config → sill AnimatedBorderView inputs)

    /// Push the `[border]` config. `effectName == "off"` (or unknown) leaves
    /// `borderEffect == nil` — the grid draws NO border then (unlike the tree
    /// panel's static primary stroke).
    public func applyBorder(effectName: String, glow: Bool, width: CGFloat,
                            cycleSeconds: CGFloat, cycleColors: Bool,
                            minWidth: CGFloat?, maxWidth: CGFloat?) {
        borderEffect = borderEffectFor(effectName)
        borderGlow = glow && borderEffect != nil
        if let mn = minWidth, let mx = maxWidth, mx > mn {
            borderLineWidth = mn
            borderBreathTo = mx
        } else {
            borderLineWidth = width
            borderBreathTo = width          // fixed width — no breathing
        }
        borderCycleSeconds = max(1, Double(cycleSeconds))
        borderCyclesColors = cycleColors
    }

    /// WS-switch flash (no-op when off — parity with the old `BorderFX`).
    public func flashBorder() {
        guard borderEffect != nil else { return }
        borderFlashToken += 1
    }
}
