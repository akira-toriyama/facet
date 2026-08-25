// The single @Observable box the SwiftUI rail binds to — the rail twin of
// the grid's `GridViewModel`. The Controller owns it: feeds the live
// snapshot (`apply` — the rail, unlike the snapshot-on-show grid, stays
// fed on every reconcile), repoints `palette` on theme ticks, drives every
// keyboard / scroll verb through its local monitors (the tree invariant:
// no view-side key handling), and reads the resolved geometry back for
// menus / zoom / hit tests.
//
// Unlike the grid there is no sill kit underneath — the carousel is
// host-side by decision (t-n3be, 2026-08-25: rule-of-three fails for the
// rail), so the VM also owns what sill's `ThemedGridView` owned for the
// grid: the pointer section-reorder drag (insertion line + ghost) and the
// cell layout itself (`railLayout`, pure). Geometry is therefore computed,
// not view-reported: hit tests and anchors read `layout` directly.

import AppKit
import CoreGraphics
import Foundation
import Observation
import FacetCore
import FacetView

// MARK: - View-facing value types

/// One window thumb, its rect NORMALIZED to the unit square — the hero and
/// the strip cell both scale it at render time, so one thumb list serves
/// both tiers (the old view scaled twice with `scaledWins`).
public struct RailThumbVM: Identifiable, Equatable {
    public let id: WindowID
    public let pid: Int
    public let isFocused: Bool
    public let norm: CGRect
    public let mark: String?
}

/// One carousel section (workspace / lens) — the §D caption, the baked
/// single-highlight, and the thumbs. `kbOrder` maps reading-order slots
/// (Tab cycling) to `thumbs` indices; `thumbs` stays in z-order.
public struct RailCellVM: Identifiable {
    public let id: String            // sectionID ("ws:<i>" / "section:…")
    public let wsIndex: Int          // 0-based source WS; -1 for a lens cell
    public let sectionType: ProjectedSectionType
    public let caption: String       // §D `index (label)`
    public let mode: String          // layout engine ("" = none)
    public let isActive: Bool
    public let thumbs: [RailThumbVM]
    public let kbOrder: [Int]
}

/// Rail layout / interaction config, set at show time.
public struct RailConfig: Sendable {
    public var edge: RailEdge
    public var cellsTarget: Int      // `[rail] cells`
    public var stripPercent: Int     // `[rail] strip`

    public init(edge: RailEdge = .bottom, cellsTarget: Int = 7,
                stripPercent: Int = 30) {
        self.edge = edge
        self.cellsTarget = cellsTarget
        self.stripPercent = stripPercent
    }
}

@MainActor
@Observable
public final class RailViewModel {

    // MARK: Inputs (Controller-supplied)

    /// Per-surface palette (`[rail].theme`); repointed on theme hot-reload
    /// AND the 30 Hz animator tick — a palette write re-colours only.
    public var palette: ResolvedPalette
    public var config = RailConfig()
    /// Display frame the windows were measured against (backend CG coords).
    public var screenFrame: CGRect = .zero
    /// The overlay's size — the Controller seeds it with the screen frame at
    /// show time; the view keeps it in sync on any resize.
    public var viewSize: CGSize = .zero

    // MARK: Callbacks (Controller-wired; same meanings as the old RailView)

    public var onDismiss: (() -> Void)?
    public var onPick: ((RailPick) -> Void)?
    public var onMoveWindow: ((_ src: Int, _ dst: Int,
                               _ pid: Int, _ id: WindowID) -> Void)?
    public var onSwap: ((_ srcWS: Int, _ dstWS: Int,
                         _ srcIDs: [WindowID], _ dstIDs: [WindowID]) -> Void)?
    public var onReorder: ((_ sectionID: String, _ toBoundary: Int) -> Void)?

    // MARK: Snapshot + derived cells

    public private(set) var cells: [RailCellVM] = []
    /// The ordered section ids the carousel cycles — `cells` order (the
    /// wrap-peek ghost is a layout artifact, never part of the cycle).
    public var sectionOrder: [String] { cells.map(\.id) }
    /// Keyboard "browse" cursor — the SECTION the centre hero previews
    /// (arrows rotate it, Return commits). Decoupled from the active
    /// section so browsing doesn't activate until commit.
    public private(set) var selectedSectionID: String?
    private var workspaces: [Workspace] = []
    private var sections: [ProjectedSection] = []
    /// Window id → home workspace index, from the UNFILTERED snapshot.
    public private(set) var windowHomeWS: [WindowID: Int] = [:]

    // MARK: Thumbnails (Controller-fed, progressive; captures only)

    public private(set) var thumbnails: [WindowID: NSImage] = [:]

    // MARK: Hover (view-reported; drives the cell ring + header brighten)

    public var hoverID: String?
    public var hoverHeaderID: String?

    // MARK: Keyboard window cursor

    /// `-1` = whole-WS slot (Space lifts the WS for a swap); `0…n-1` = a
    /// reading-order hero window (Space lifts it for a move).
    public private(set) var kbWindowIdx: Int = -1

    // MARK: Host drag (window move + workspace swap + section reorder)

    enum HostDragKind: Equatable {
        case window(pid: Int, id: WindowID, sourceWS: Int,
                    sourceCellID: String, thumbSize: CGSize)
        case workspaceSwap(sourceCellID: String, sourceWS: Int)
        /// Mouse header drag — display-only section reorder (the keyboard
        /// header lift is the SWAP above; the two never mix).
        case reorder(sourceCellID: String)
    }
    struct HostDrag {
        var kind: HostDragKind
        var location: CGPoint            // rail-space ghost anchor
        var targetCellID: String?        // window / swap drop target
        var reorderBoundary: Int?        // reorder insertion boundary
        var reorderLine: (a: CGPoint, b: CGPoint)?
        var isKeyboard: Bool
    }
    private(set) var drag: HostDrag?
    /// The dragged window stays hidden in BOTH tiers through the drag and
    /// the landing gate (the ghost stands in) — cleared on backend ack.
    private(set) var hiddenThumbID: WindowID?

    /// Landing gates (FacetCore, shared with the grid): drag visuals
    /// persist until the backend reflects the move/swap.
    private var lastDrop: OverviewPendingDrop?
    private var lastSwap: OverviewPendingSwap?

    // MARK: Refresh suppression (the old `layoutSuppressed`)

    /// True while any pointer button is down inside the overlay (the
    /// monitor maintains it); a deferred snapshot flushes on release.
    public var pointerBusy = false { didSet { if !pointerBusy { flushPending() } } }
    private var pendingApply: (wss: [Workspace], secs: [ProjectedSection])?

    // MARK: Carousel slide (2-b v2) + hero crossfade

    /// Along-axis translation added to the strip cells while a rotation
    /// eases in; 0 when settled.
    public private(set) var slideOffset: CGFloat = 0
    /// Ease value (0→1) of the active slide — also fades the previous
    /// hero snapshot out (the browse crossfade).
    public private(set) var slideProgress: CGFloat = 1
    private var slideFrom: CGFloat = 0
    private var slideStart: Date?
    private var slideTimer: Timer?
    public private(set) var prevHeroImage: NSImage?
    public private(set) var prevHeroRect: CGRect = .zero
    /// Scroll-wheel accumulation (`wheelSteps`).
    private var scrollAccum: CGFloat = 0

    // MARK: Commit zoom (hero → full screen on a centre commit)

    struct ZoomPose { let image: NSImage; let from: CGRect }
    private(set) var zoom: ZoomPose?
    var zoomExpanded = false
    private var zoomPerform: (() -> Void)?
    /// Captures a region of the live rendering (the Controller wires the
    /// hosting view's `snapshotRegion`) — feeds the zoom AND the crossfade.
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

    // MARK: - Geometry (computed — the host owns the layout, so hit tests
    // and anchors read it directly; no preference round-trip)

    public var layout: RailLayout {
        railLayout(bounds: CGRect(origin: .zero, size: viewSize),
                   edge: config.edge,
                   screen: screenFrame,
                   count: cells.count,
                   cellsTarget: config.cellsTarget,
                   stripPercent: config.stripPercent,
                   selectedPos: selectedPos)
    }

    /// The selected section's position in `cells` — the carousel centre.
    /// Falls back to the active cell, then 0 (the old resolution chain).
    public var selectedPos: Int {
        cells.firstIndex(where: { $0.id == selectedSectionID })
            ?? cells.firstIndex(where: { $0.isActive })
            ?? 0
    }

    public var selectedCell: RailCellVM? {
        cells.isEmpty ? nil : cells[min(selectedPos, cells.count - 1)]
    }

    /// The hero previews the SELECTED section (same resolution chain).
    public var heroCell: RailCellVM? { selectedCell }

    // MARK: - Snapshot application (landing gates + suppression — the old
    // `layoutCells` gate order, then the Controller's re-centre rule)

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
        // External-activate re-centre (the old Controller-side rule): when
        // the cursor sits on the ACTIVE section and the active section
        // changes under us (CLI switch), follow it — but never yank a
        // mid-browse cursor parked elsewhere.
        let oldActiveID = cells.first(where: { $0.isActive })?.id
        let followActive = selectedSectionID != nil && selectedSectionID == oldActiveID
        workspaces = wss
        sections = secs
        rebuild()
        if followActive, let newActive = cells.first(where: { $0.isActive })?.id {
            selectedSectionID = newActive
        }
        if droppedLanded {
            lastDrop = nil; drag = nil; hiddenThumbID = nil
        }
        if swapLanded {
            lastSwap = nil; drag = nil
        }
    }

    private func flushPending() {
        guard let p = pendingApply, !suppressed else { return }
        pendingApply = nil
        apply(workspaces: p.wss, sections: p.secs)
    }

    /// EX-2b: one cell per projected section (workspace + lens) when the
    /// section model is active, else one per workspace (byte-identical
    /// degrade). The §D caption composes here.
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
                    // An isolate desktop is TREE-ONLY; nothing mints these
                    // for the rail — but the switch stays exhaustive.
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
        cells = sources.map { src in
            var thumbs: [RailThumbVM] = []
            if screenFrame.width > 0 {
                for win in src.windows {
                    guard let f = win.frame else { continue }
                    let n = scaledWindowRect(windowFrame: f,
                                             screenFrame: screenFrame,
                                             cellRect: unit)
                    guard n.width > 0, n.height > 0 else { continue }
                    thumbs.append(RailThumbVM(id: win.id, pid: win.pid,
                                              isFocused: win.isFocused,
                                              norm: n, mark: win.mark))
                }
            }
            let hits = thumbs.map {
                MiniWindowHit(pid: $0.pid, id: $0.id, isFocused: $0.isFocused,
                              rect: $0.norm, mark: $0.mark)
            }
            let ordered = readingOrder(hits)
            let kbOrder = ordered.compactMap { o in thumbs.firstIndex { $0.id == o.id } }
            return RailCellVM(id: src.sectionID, wsIndex: src.wsIndex,
                              sectionType: src.sectionType, caption: src.label,
                              mode: src.mode, isActive: src.isActive,
                              thumbs: thumbs, kbOrder: kbOrder)
        }

        // Stranded-cursor repair + first seed: a vanished (or never-set)
        // browse cursor snaps to the active section, then the first cell.
        if !cells.contains(where: { $0.id == selectedSectionID }) {
            selectedSectionID = (cells.first(where: { $0.isActive }) ?? cells.first)?.id
            kbWindowIdx = -1
        }
        if let d = drag, !cells.contains(where: { $0.id == sourceCellID(of: d) }) {
            cancelDrag()
        }
    }

    private func sourceCellID(of d: HostDrag) -> String {
        switch d.kind {
        case .window(_, _, _, let cell, _): return cell
        case .workspaceSwap(let cell, _):   return cell
        case .reorder(let cell):            return cell
        }
    }

    // MARK: - Thumbnails

    public func setThumbnail(_ image: NSImage, for id: WindowID) {
        thumbnails[id] = image
    }

    public func clearThumbnails() {
        thumbnails.removeAll()
    }

    // MARK: - Carousel slide + crossfade (60 fps timer, ease-out cubic —
    // the SwiftUI implicit animation can't retarget an accumulating
    // offset mid-flight, so the old timer drive stays)

    private func startSlide(step dx: Int, slot: CGFloat) {
        guard dx != 0, slot > 0, !reduceMotionCheck()
        else { slideOffset = 0; stopSlide(); return }
        let cap = slot * railSlideMaxSlots
        slideOffset = max(-cap, min(cap, slideOffset + CGFloat(dx) * slot))
        slideFrom = slideOffset
        slideProgress = 0
        slideStart = Date()
        if slideTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickSlide() }
            }
            RunLoop.main.add(timer, forMode: .common)   // fire during key-mash too
            slideTimer = timer
        }
    }

    private func tickSlide() {
        guard let start = slideStart else { stopSlide(); return }
        let t = Date().timeIntervalSince(start) / railSlideDuration
        if t >= 1 {
            slideOffset = 0; slideProgress = 1
            stopSlide()
        } else {
            let e = 1 - pow(1 - CGFloat(t), 3)   // ease-out cubic
            slideOffset = slideFrom * (1 - e)
            slideProgress = e
        }
    }

    private func stopSlide() {
        slideTimer?.invalidate(); slideTimer = nil; slideStart = nil
        slideProgress = 1
        prevHeroImage = nil          // crossfade done
    }

    /// Overlay teardown: settle the slide and fire a pending zoom's switch
    /// (closed mid-zoom must not drop it).
    public func teardown() {
        slideOffset = 0
        stopSlide()
        if zoomPerform != nil { finishZoom() }
    }

    // MARK: - Keyboard (host monitor → these verbs)

    /// The reading-order slot the window cursor points at, resolved to the
    /// z-order thumb index (shared by the hero ring + strip ring + lifts).
    public var kbSelectedThumb: (cell: RailCellVM, thumb: RailThumbVM, thumbIndex: Int)? {
        guard kbWindowIdx >= 0, let cell = selectedCell, !cell.thumbs.isEmpty
        else { return nil }
        let slot = max(0, min(cell.kbOrder.count - 1, kbWindowIdx))
        let ti = cell.kbOrder[slot]
        return (cell, cell.thumbs[ti], ti)
    }

    /// Browse arrow along the strip axis: rotate the carousel one section
    /// (circular, lenses included). Lifted → the new centre is the aim.
    public func kbMoveSelection(dx: Int) {
        guard zoom == nil, !cells.isEmpty else { return }
        let order = sectionOrder
        let m = order.count
        let cur = order.firstIndex(of: selectedSectionID ?? "") ?? 0
        let ni = (cur + dx + m) % m
        guard order[ni] != selectedSectionID else { return }
        // Browse crossfade: snapshot the current hero before it changes.
        if drag == nil, layout.heroRect != .zero {
            prevHeroImage = snapshotProvider?(layout.heroRect)
            prevHeroRect = layout.heroRect
        }
        let slot = layout.slot
        selectedSectionID = order[ni]
        if drag != nil {
            // Lifted: the carousel rotates under the ghost; centre = target.
            syncKbDragToSelection()
        } else {
            kbWindowIdx = -1
            startSlide(step: dx, slot: slot)
        }
    }

    /// Tab / Shift-Tab: cycle the hero's windows + the whole-WS slot (-1).
    public func kbCycleWindow(forward: Bool) {
        guard zoom == nil, drag == nil, let cell = selectedCell else { return }
        kbWindowIdx = cycleSlotIndex(current: kbWindowIdx,
                                     windowCount: cell.thumbs.count,
                                     forward: forward)
    }

    /// Space is a TOGGLE: carrying → drop (= Return), otherwise lift
    /// whatever is selected (window move / whole-WS swap).
    public func kbSpaceLift() {
        guard zoom == nil else { return }
        if drag != nil { kbCommit(); return }
        if kbWindowIdx == -1 { kbLiftWorkspace() } else { kbLiftWindow() }
    }

    private func kbLiftWindow() {
        // A window inside a non-workspace hero is not move-liftable (no
        // source WS, Decision 6).
        guard drag == nil, !pointerBusy, let s = kbSelectedThumb,
              s.cell.sectionType == .workspace else { return }
        // Ghost at the BOTTOM cell's thumb size (small), the old lift feel;
        // hero-rect fallback when the strip thumb culled away.
        let size = stripThumbRect(cellID: s.cell.id, thumbIndex: s.thumbIndex)?.size
            ?? heroThumbRect(thumbIndex: s.thumbIndex)?.size
            ?? CGSize(width: 96, height: 64)
        let at = cellAnchor(s.cell.id)
        drag = HostDrag(
            kind: .window(pid: s.thumb.pid, id: s.thumb.id,
                          sourceWS: s.cell.wsIndex,
                          sourceCellID: s.cell.id, thumbSize: size),
            location: at, targetCellID: nil,
            reorderBoundary: nil, reorderLine: nil, isKeyboard: true)
        hiddenThumbID = s.thumb.id
    }

    private func kbLiftWorkspace() {
        guard drag == nil, !pointerBusy, let cell = selectedCell,
              cell.sectionType == .workspace else { return }
        drag = HostDrag(
            kind: .workspaceSwap(sourceCellID: cell.id, sourceWS: cell.wsIndex),
            location: cellAnchor(cell.id), targetCellID: nil,
            reorderBoundary: nil, reorderLine: nil, isKeyboard: true)
    }

    /// While lifted via keyboard, the carousel CENTRE is the drop target —
    /// valid only on a workspace cell that isn't the source.
    private func syncKbDragToSelection() {
        guard var d = drag, let cell = selectedCell else { return }
        let srcWS: Int
        switch d.kind {
        case .window(_, _, let s, _, _):  srcWS = s
        case .workspaceSwap(_, let s):    srcWS = s
        case .reorder:                    return   // mouse-only, never keyboard
        }
        d.targetCellID = (cell.sectionType != .workspace || cell.wsIndex == srcWS)
            ? nil : cell.id
        d.location = cellAnchor(cell.id)
        drag = d
    }

    /// Return: lifted → commit the move/swap (stay open; cancel when aimed
    /// home/nowhere); else switch to the selection — the selection IS the
    /// centre, so the hero zoom always plays.
    public func kbCommit() {
        guard zoom == nil else { return }
        // A commit already awaits the backend ack — swallow a second Return
        // so it can't fire a duplicate move/swap before the gate clears.
        if lastDrop != nil || lastSwap != nil { return }
        if let d = drag {
            if let tid = d.targetCellID, let dst = cells.first(where: { $0.id == tid }) {
                switch d.kind {
                case .window(let pid, let id, let srcWS, _, _):
                    commitWindowDrop(pid: pid, id: id, sourceWS: srcWS, dstCell: dst)
                case .workspaceSwap(let srcCellID, let srcWS):
                    commitSwap(sourceCellID: srcCellID, sourceWS: srcWS, dstCell: dst)
                case .reorder:
                    cancelDrag()
                }
            } else {
                cancelDrag()
            }
            return
        }
        guard let cell = selectedCell else { return }
        if let s = kbSelectedThumb {
            let home = windowHomeWS[s.thumb.id] ?? cell.wsIndex
            commitSwitch(targetSectionID: cell.id) { [weak self] in
                self?.onPick?(.window(homeWorkspaceIndex: home,
                                      pid: s.thumb.pid, windowID: s.thumb.id))
            }
        } else {
            commitSwitch(targetSectionID: cell.id) { [weak self] in
                self?.onPick?(.workspace(workspaceIndex: cell.wsIndex))
            }
        }
    }

    /// Esc, in order: cancel an in-flight lift → clear a Tab window
    /// selection (stay open) → dismiss the rail. Inert mid-zoom.
    public func kbEscape() {
        guard zoom == nil else { return }
        if drag != nil {
            cancelDrag()
        } else if kbWindowIdx != -1 {
            kbWindowIdx = -1
        } else {
            onDismiss?()
        }
    }

    // MARK: - Scroll browse (Controller's scroll monitor feeds this)

    /// Mouse-wheel / two-finger scroll rotates the carousel: down → next,
    /// up → previous, on every edge. Inert while lifted / dragging.
    public func scrollRotate(deltaY: CGFloat, precise: Bool,
                             gestureBegan: Bool, isMomentum: Bool) {
        guard drag == nil, !isMomentum else { return }
        guard cells.count > 1 else { return }
        let steps = wheelSteps(deltaY: deltaY, accum: &scrollAccum,
                               threshold: railScrollStep,
                               precise: precise,
                               gestureBegan: gestureBegan)
        let dx = steps < 0 ? -1 : 1
        for _ in 0..<abs(steps) { kbMoveSelection(dx: dx) }
    }

    // MARK: - Pointer picks

    public func tapBackdrop() {
        guard zoom == nil, drag == nil else { return }
        onDismiss?()
    }

    /// Empty cell area / header click → switch (zoom iff it's the centre).
    public func tapCell(_ cellID: String) {
        guard zoom == nil, drag == nil else { return }
        guard let cell = cells.first(where: { $0.id == cellID }) else { return }
        commitSwitch(targetSectionID: cellID) { [weak self] in
            self?.onPick?(.workspace(workspaceIndex: cell.wsIndex))
        }
    }

    /// Window thumb click (hero or strip) → switch to its HOME WS and
    /// focus that window (zoom iff its cell is the centre).
    public func tapThumb(cellID: String, thumb: RailThumbVM) {
        guard zoom == nil, drag == nil else { return }
        guard let cell = cells.first(where: { $0.id == cellID }) else { return }
        let home = windowHomeWS[thumb.id] ?? cell.wsIndex
        commitSwitch(targetSectionID: cellID) { [weak self] in
            self?.onPick?(.window(homeWorkspaceIndex: home,
                                  pid: thumb.pid, windowID: thumb.id))
        }
    }

    // MARK: - Pointer window drag (hero = primary source, strip = secondary)

    public func thumbDragChanged(cellID: String, thumb: RailThumbVM,
                                 thumbIndex: Int, location: CGPoint) {
        guard zoom == nil else { return }
        if drag == nil {
            // A keyboard lift owns the gesture space — a stray mouse drag
            // must not hijack its aim (the old pendingDown guard).
            guard let cell = cells.first(where: { $0.id == cellID }),
                  cell.sectionType == .workspace else { return }
            let size = stripThumbRect(cellID: cellID, thumbIndex: thumbIndex)?.size
                ?? heroThumbRect(thumbIndex: thumbIndex)?.size
                ?? CGSize(width: 96, height: 64)
            drag = HostDrag(
                kind: .window(pid: thumb.pid, id: thumb.id,
                              sourceWS: cell.wsIndex,
                              sourceCellID: cellID, thumbSize: size),
                location: location, targetCellID: nil,
                reorderBoundary: nil, reorderLine: nil, isKeyboard: false)
            hiddenThumbID = thumb.id
        }
        guard var d = drag, !d.isKeyboard, case .window = d.kind else { return }
        d.location = location
        d.targetCellID = moveTarget(at: location, excludingWS: sourceWS(of: d))
        drag = d
    }

    public func thumbDragEnded() {
        guard let d = drag, !d.isKeyboard, case .window(let pid, let id,
            let srcWS, _, _) = d.kind else { return }
        if let tid = d.targetCellID, let dst = cells.first(where: { $0.id == tid }) {
            commitWindowDrop(pid: pid, id: id, sourceWS: srcWS, dstCell: dst)
        } else {
            cancelDrag()
        }
    }

    private func sourceWS(of d: HostDrag) -> Int {
        switch d.kind {
        case .window(_, _, let s, _, _): return s
        case .workspaceSwap(_, let s):   return s
        case .reorder:                   return -1
        }
    }

    /// The workspace strip cell (≠ source) under `point` — a window move's
    /// only valid landing (never the hero, never a lens cell), gated by the
    /// carousel viewport like every strip hit.
    private func moveTarget(at point: CGPoint, excludingWS: Int) -> String? {
        guard let cell = stripCellAt(point),
              cell.sectionType == .workspace, cell.wsIndex != excludingWS
        else { return nil }
        return cell.id
    }

    // MARK: - Pointer section reorder (mouse header drag — display-only;
    // what sill's kit owned for the grid, host-side here)

    public func headerDragChanged(cellID: String, location: CGPoint) {
        guard zoom == nil else { return }
        if drag == nil {
            // BOTH workspace + lens headers arm a reorder (the old rule);
            // a keyboard lift in flight blocks the mouse (isKeyboard guard).
            guard cells.contains(where: { $0.id == cellID }) else { return }
            drag = HostDrag(kind: .reorder(sourceCellID: cellID),
                            location: location, targetCellID: nil,
                            reorderBoundary: nil, reorderLine: nil,
                            isKeyboard: false)
        }
        guard var d = drag, !d.isKeyboard, case .reorder(let srcID) = d.kind,
              srcID == cellID else { return }
        d.location = location
        let (boundary, line) = reorderTarget(at: location, draggedID: srcID)
        d.reorderBoundary = boundary
        d.reorderLine = line
        drag = d
    }

    public func headerDragEnded() {
        guard let d = drag, !d.isKeyboard,
              case .reorder(let srcID) = d.kind else { return }
        if let b = d.reorderBoundary {
            onReorder?(srcID, b)
        }
        // Display-only: no backend round-trip, no gate — clear now.
        drag = nil
        flushPending()
    }

    /// Insertion boundary (sectionOrder coords) + line endpoints for the
    /// strip cell under the cursor; nil off all cells or on the dragged
    /// section's own slot.
    private func reorderTarget(at p: CGPoint, draggedID: String)
        -> (Int?, (a: CGPoint, b: CGPoint)?) {
        let lay = layout
        guard let cell = stripCellAt(p),
              let t = cells.firstIndex(where: { $0.id == cell.id }),
              let placement = lay.placements.first(where: {
                  !$0.isWrapGhost && $0.sourceIndex == t })
        else { return (nil, nil) }
        let horizontal = config.edge.axis == .horizontal
        let r = placement.cellRect
        let after = horizontal ? (p.x >= r.midX) : (p.y >= r.midY)
        let b = after ? t + 1 : t
        if let s = cells.firstIndex(where: { $0.id == draggedID }),
           b == s || b == s + 1 {
            return (nil, nil)          // own slot → no-op
        }
        let line: (CGPoint, CGPoint)
        if horizontal {
            let x = after ? r.maxX : r.minX
            line = (CGPoint(x: x, y: r.minY), CGPoint(x: x, y: r.maxY))
        } else {
            let y = after ? r.maxY : r.minY
            line = (CGPoint(x: r.minX, y: y), CGPoint(x: r.maxX, y: y))
        }
        return (b, line)
    }

    // MARK: - Commits (landing-gated) + cancel

    private func commitWindowDrop(pid: Int, id: WindowID, sourceWS: Int,
                                  dstCell: RailCellVM) {
        lastDrop = OverviewPendingDrop(id: id, dstWS: dstCell.wsIndex,
                                       committedAt: Date())
        // `drag` + `hiddenThumbID` stay set: the ghost stands in until the
        // backend acks (cleared in `apply`'s landed path or its timeout).
        onMoveWindow?(sourceWS, dstCell.wsIndex, pid, id)
        scheduleAckDeadline()
    }

    private func commitSwap(sourceCellID: String, sourceWS: Int,
                            dstCell: RailCellVM) {
        // Both swap sets from the LIVE workspaces (frameless / sub-2pt
        // windows have no thumb but must still move) — the old rule.
        let srcIDs = workspaces.first(where: { $0.index == sourceWS })?
            .windows.map(\.id)
            ?? cells.first(where: { $0.id == sourceCellID })?.thumbs.map(\.id)
            ?? []
        let dstIDs = workspaces.first(where: { $0.index == dstCell.wsIndex })?
            .windows.map(\.id) ?? dstCell.thumbs.map(\.id)
        if srcIDs.isEmpty && dstIDs.isEmpty {
            cancelDrag()
            return
        }
        lastSwap = OverviewPendingSwap(srcWS: sourceWS, dstWS: dstCell.wsIndex,
                                       srcIDs: srcIDs, dstIDs: dstIDs,
                                       committedAt: Date())
        onSwap?(sourceWS, dstCell.wsIndex, srcIDs, dstIDs)
        scheduleAckDeadline()
    }

    /// The landing gate's timeout is only evaluated when a snapshot
    /// arrives; a silent backend no-op would otherwise freeze the gesture
    /// until the next reconcile. One deferred re-apply honours it.
    private func scheduleAckDeadline() {
        DispatchQueue.main.asyncAfter(deadline: .now() + overviewDropAckTimeout) {
            [weak self] in
            guard let self else { return }
            self.apply(workspaces: self.workspaces, sections: self.sections)
        }
    }

    public func cancelDrag() {
        // A KEYBOARD aim advances selectedSectionID while lifted — the
        // selection (and with it the hero + carousel) simply stays where
        // the aim left it, matching the old cancel's re-lay.
        drag = nil
        hiddenThumbID = nil
        lastDrop = nil
        lastSwap = nil
        flushPending()
    }

    /// Backstop for a pointer drag whose SwiftUI gesture died without an
    /// `onEnded` (the mouse monitor always sees the up event). Ends the
    /// window drag or the reorder at its current target; a keyboard lift
    /// is untouched (it ends by key).
    public func pointerDragEndFallback() {
        guard let d = drag, !d.isKeyboard else { return }
        switch d.kind {
        case .window:        thumbDragEnded()
        case .reorder:       headerDragEnded()
        case .workspaceSwap: cancelDrag()      // unreachable: swap is kb-only
        }
    }

    // MARK: - Geometry helpers (hit tests / anchors — all rail-space)

    /// The strip cell under `p`, gated by the carousel viewport (a cell
    /// rotated past the clip never matches, even in the outer margin).
    /// Wrap-ghost placements resolve to their source cell.
    public func stripCellAt(_ p: CGPoint) -> RailCellVM? {
        let lay = layout
        guard lay.stripRect.contains(p) else { return nil }
        for pl in lay.placements
        where pl.cellRect.contains(p) || pl.headerRect.contains(p) {
            if cells.indices.contains(pl.sourceIndex) { return cells[pl.sourceIndex] }
        }
        return nil
    }

    /// The strip cell whose HEADER band contains `p` (viewport-gated).
    public func headerCellAt(_ p: CGPoint) -> RailCellVM? {
        let lay = layout
        guard lay.stripRect.contains(p) else { return nil }
        for pl in lay.placements where pl.headerRect.contains(p) {
            if cells.indices.contains(pl.sourceIndex) { return cells[pl.sourceIndex] }
        }
        return nil
    }

    /// The topmost window thumb under `p` — hero first (it draws the full
    /// window list large), then the viewport-gated strip cells.
    public func thumbAt(_ p: CGPoint)
        -> (cell: RailCellVM, thumb: RailThumbVM, thumbIndex: Int)? {
        let lay = layout
        if let hero = heroCell, lay.heroRect.contains(p) {
            for ti in hero.thumbs.indices.reversed() {
                if absRect(hero.thumbs[ti].norm, in: lay.heroRect).contains(p) {
                    return (hero, hero.thumbs[ti], ti)
                }
            }
        }
        guard lay.stripRect.contains(p) else { return nil }
        for pl in lay.placements where pl.cellRect.contains(p) {
            guard cells.indices.contains(pl.sourceIndex) else { continue }
            let cell = cells[pl.sourceIndex]
            for ti in cell.thumbs.indices.reversed() {
                let r = absRect(cell.thumbs[ti].norm, in: pl.cellRect)
                if r.width >= 2, r.height >= 2, r.contains(p) {
                    return (cell, cell.thumbs[ti], ti)
                }
            }
        }
        return nil
    }

    /// A cell's primary (non-ghost) strip placement.
    public func placement(of cellID: String) -> RailCellPlacement? {
        guard let i = cells.firstIndex(where: { $0.id == cellID }) else { return nil }
        return layout.placements.first { !$0.isWrapGhost && $0.sourceIndex == i }
    }

    /// A thumb's absolute rect inside its strip cell (nil when culled).
    public func stripThumbRect(cellID: String, thumbIndex: Int) -> CGRect? {
        guard let pl = placement(of: cellID),
              let cell = cells.first(where: { $0.id == cellID }),
              cell.thumbs.indices.contains(thumbIndex) else { return nil }
        let r = absRect(cell.thumbs[thumbIndex].norm, in: pl.cellRect)
        return (r.width >= 2 && r.height >= 2) ? r : nil
    }

    /// A hero thumb's absolute rect (nil when the hero is down).
    public func heroThumbRect(thumbIndex: Int) -> CGRect? {
        let lay = layout
        guard lay.heroRect != .zero, let hero = heroCell,
              hero.thumbs.indices.contains(thumbIndex) else { return nil }
        return absRect(hero.thumbs[thumbIndex].norm, in: lay.heroRect)
    }

    private func cellAnchor(_ cellID: String) -> CGPoint {
        guard let pl = placement(of: cellID) else { return .zero }
        return CGPoint(x: pl.cellRect.midX, y: pl.cellRect.midY)
    }

    func absRect(_ norm: CGRect, in box: CGRect) -> CGRect {
        CGRect(x: box.minX + norm.minX * box.width,
               y: box.minY + norm.minY * box.height,
               width: norm.width * box.width,
               height: norm.height * box.height)
    }

    // MARK: - Ghost view inputs

    /// The floating card for a WINDOW drag: capture > accent tile (the
    /// rail never falls back to app icons).
    public var windowGhost: (image: NSImage?, size: CGSize, location: CGPoint)? {
        guard let d = drag, case .window(_, let id, _, _, let size) = d.kind
        else { return nil }
        return (image: thumbnails[id], size: size, location: d.location)
    }

    /// The floating cell card for a workspace SWAP lift or a section
    /// REORDER drag: the source cell's thumbs in place (capture /
    /// placeholder fill), or the centred WS label when empty.
    public var workspaceGhost: (cell: RailCellVM, size: CGSize, location: CGPoint)? {
        guard let d = drag else { return nil }
        let srcID: String
        switch d.kind {
        case .workspaceSwap(let s, _): srcID = s
        case .reorder(let s):          srcID = s
        case .window:                  return nil
        }
        guard let cell = cells.first(where: { $0.id == srcID }) else { return nil }
        let size = placement(of: srcID)?.cellRect.size ?? CGSize(width: 96, height: 64)
        return (cell: cell, size: size, location: d.location)
    }

    /// The lifted source cell (dim + thin stroke): the reorder keys by
    /// sectionID; the keyboard swap keys by wsIndex — the old rule kept.
    public func isDragSource(_ cell: RailCellVM) -> Bool {
        guard let d = drag else { return false }
        switch d.kind {
        case .reorder(let srcID):        return cell.id == srcID
        case .workspaceSwap(_, let ws):  return cell.wsIndex == ws
        case .window:                    return false
        }
    }

    /// The drop-target ring / fill for a cell, colour-keyed by drag kind.
    public enum DropHighlight { case window, swap }
    public func dropHighlight(_ cell: RailCellVM) -> DropHighlight? {
        guard let d = drag, d.targetCellID == cell.id else { return nil }
        switch d.kind {
        case .window:        return .window
        case .workspaceSwap: return .swap
        case .reorder:       return nil
        }
    }

    // MARK: - Commit zoom

    /// Funnel for a switch-and-close commit: the hero zoom plays iff the
    /// picked section IS the centred hero; otherwise `perform` runs now.
    public func commitSwitch(targetSectionID: String,
                             perform: @escaping () -> Void) {
        guard zoom == nil else { return }
        let lay = layout
        guard targetSectionID == selectedCell?.id, lay.heroRect != .zero,
              !reduceMotionCheck(),
              let img = snapshotProvider?(lay.heroRect)
        else { perform(); return }
        zoomPerform = perform
        zoomExpanded = false
        zoom = ZoomPose(image: img, from: lay.heroRect)
    }

    /// Fire the pending switch exactly once — the animation's completion,
    /// or the teardown path.
    public func finishZoom() {
        let p = zoomPerform
        zoomPerform = nil
        zoom = nil
        zoomExpanded = false
        p?()
    }

    // MARK: - Border ([border] config → sill AnimatedBorderView inputs)

    /// Push the `[border]` config. `effectName == "off"` (or unknown)
    /// leaves `borderEffect == nil` — the rail frames the screen edge only
    /// while an effect is active (the old BorderFX contract).
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
            borderBreathTo = width
        }
        borderCycleSeconds = max(1, Double(cycleSeconds))
        borderCyclesColors = cycleColors
    }

    /// WS-switch / show flash (no-op when off).
    public func flashBorder() {
        guard borderEffect != nil else { return }
        borderFlashToken += 1
    }
}
