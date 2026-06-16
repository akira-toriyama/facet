// Scratchpad shelf (stash / toggle / release) plus the frame-apply
// machinery that lives in the same cluster: applyStack / applyTile /
// applyEngine / applyFrames, live-resize follow, close / reveal,
// `perform(_:)` action dispatch, and the window context menu.
// Extracted unchanged from NativeAdapter.swift (#182 phase 4) —
// same-module extension, no logic change. Stored state
// (followAXCache) stays on the primary declaration.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import FacetAccessibility
import FacetCore

extension NativeAdapter {
    // MARK: - Scratchpad shelf (stash / toggle / release)

    public func stashScratchpad(_ name: String) -> Bool {
        guard let id = focusedWindow() else {
            Log.debug("native: scratchpad --stash \"\(name)\" — no focus")
            return false
        }
        let rect = activeDisplayRect()
        guard catalog.stashWindow(name, id: id) else {
            Log.debug("native: scratchpad --stash \"\(name)\" — "
                + "\(id.serverID) not managed")
            return false
        }
        // Hide it off-screen (the catalog already detached + force-
        // floated it), then reflow so the neighbours fill the freed slot.
        if let slot = catalog.windowMap[id] {
            parkAnchor(WindowRef(id: id, pid: slot.pid))
        }
        Log.debug("native: scratchpad --stash \"\(name)\" -> \(id.serverID)")
        reflowActive(rect: rect)
        eventContinuation.yield(.refreshNeeded)
        return true
    }

    public func toggleScratchpad(_ name: String) -> Bool {
        guard let id = catalog.window(forScratchpad: name),
              let slot = catalog.windowMap[id] else {
            Log.debug("native: scratchpad --toggle \"\(name)\" — unset / gone")
            return false
        }
        let rect = activeDisplayRect()
        let ref = WindowRef(id: id, pid: slot.pid)
        if catalog.isScratchpadVisibleHere(name) {
            // Visible on the current WS → re-park it onto the shelf.
            _ = catalog.restashScratchpad(name)
            parkAnchor(ref)
        } else {
            // Stashed, or settled on another WS → summon it onto the
            // current WS. `restoreAnchor` no-ops when not parked.
            _ = catalog.summonScratchpad(name)
            restoreAnchor(ref)
            if let win = enumerateCGWindows().first(where: { $0.id == id }) {
                Focus.assert(win, backend: self)   // focus doesn't auto-jump
            }
        }
        Log.debug("native: scratchpad --toggle \"\(name)\" -> "
            + "\(id.serverID) stashed=\(catalog.isStashed(id))")
        reflowActive(rect: rect)
        eventContinuation.yield(.refreshNeeded)
        return true
    }

    public func releaseScratchpad(_ name: String) -> Bool {
        guard let id = catalog.window(forScratchpad: name),
              let slot = catalog.windowMap[id] else {
            Log.debug("native: scratchpad --release \"\(name)\" — no such shelf")
            return false
        }
        let rect = activeDisplayRect()
        let ref = WindowRef(id: id, pid: slot.pid)
        // Drop the shelf + un-float + attach to the active WS's layout
        // first, then position it. A tiling WS re-tiles it from wherever
        // it sits, so just clear the stale park bookkeeping (no
        // intermediate jump to the recorded position). A float-mode WS
        // doesn't tile, so restore it to its pre-stash position on-screen.
        _ = catalog.releaseScratchpad(name, focused: id, in: rect)
        if catalog.mode(of: catalog.activeIndex) == "float" {
            restoreAnchor(ref)
        } else {
            catalog.clearParkedState(of: id)
        }
        Log.debug("native: scratchpad --release \"\(name)\" -> \(id.serverID)")
        reflowActive(rect: rect)
        eventContinuation.yield(.refreshNeeded)
        return true
    }

    public func stashedScratchpads() -> [String] {
        catalog.stashedScratchpadNames()
    }

    /// Apply stack mode to `n1Based`: the catalog's
    /// `stackOrder[0]` fills `rect` (un-parked from the anchor
    /// sliver), all other members are parked there. Floating
    /// windows are excluded entirely (they live outside the
    /// stack). No-op when the WS isn't in stack mode or has no
    /// members.
    func applyStack(workspace n1Based: Int, rect: CGRect) {
        let order = catalog.stackOrder(of: n1Based)
        guard let top = order.first else { return }
        // Top: force visible, full rect. Bypass the regular
        // restore flow (which would use the recorded
        // originalPosition); the stack contract is that top
        // fills the display.
        if let pid = catalog.pid(for: top),
           let ax = AXGeom.window(for: CGWindowID(top.serverID),
                                  pid: pid_t(pid))
        {
            AXGeom.setPosition(ax, rect.origin)
            AXGeom.setSize(ax, rect.size)
            catalog.clearParkedState(of: top)
        }
        // Others: park at the anchor sliver (parkAnchor owns the
        // "skip if already parked" guard).
        for id in order.dropFirst() {
            guard let pid = catalog.pid(for: id) else { continue }
            parkAnchor(WindowRef(id: id, pid: pid))
        }
        Log.debug("native: stack WS \(n1Based) "
            + "top=\(top.serverID) members=\(order.count) "
            + "rect=\(rect)")
    }

    /// Iterate the WS's tree-computed frames and push each one
    /// through AX. Floating windows are skipped (they're not in
    /// the tree). No-op when the WS has no tree.
    private func applyTile(workspace n1Based: Int, rect: CGRect,
                           skip: Set<WindowID> = [], cached: Bool = false) {
        applyFrames(catalog.tiledFrames(for: n1Based, in: rect),
                    label: "tile WS \(n1Based)", rect: rect, skip: skip,
                    cached: cached)
    }

    /// Apply a stateless `LayoutEngine`'s frames for `n1Based`. The
    /// engine path: catalog computes pure geometry, this pushes it
    /// through AX exactly like `applyTile`.
    private func applyEngine(workspace n1Based: Int, rect: CGRect,
                             skip: Set<WindowID> = [], cached: Bool = false) {
        applyFrames(catalog.engineFrames(for: n1Based, in: rect),
                    label: "engine WS \(n1Based)", rect: rect, skip: skip,
                    cached: cached)
    }

    /// The drag's cached AX element for `id`, resolved + memoised on first
    /// use (the lookup that was the per-tick bottleneck).
    private func cachedFollowAX(_ id: WindowID) -> AXUIElement? {
        if let ax = followAXCache[id] { return ax }
        guard let pid = catalog.pid(for: id),
              let ax = AXGeom.window(for: CGWindowID(id.serverID),
                                     pid: pid_t(pid)) else { return nil }
        followAXCache[id] = ax
        return ax
    }

    /// Drop the per-drag live-follow cache. Called once at gesture end
    /// (the `WindowBackend.endLiveResize` hook) for ANY outcome — resize
    /// settle, move, or an unread final frame — so a stale element never
    /// crosses into the next drag. Runs on the gesture's cliQueue.
    public func endLiveResize() {
        followAXCache.removeAll(keepingCapacity: true)
    }

    /// Shared AX writer: set each window's position + size from a
    /// pre-computed frame map. Used by both the bsp tree path and
    /// the stateless-engine path.
    private func applyFrames(_ frames: [WindowID: CGRect],
                             label: String, rect: CGRect,
                             skip: Set<WindowID> = [],
                             cached: Bool = false) {
        // Inner gap: pull abutting windows apart. The screen-edge
        // side of an outermost window stays flush — that distance is
        // the outer gap, already inset into `rect`. No-op when 0.
        let frames = applyInnerGap(frames, in: rect,
                                   gap: config.effectiveInnerGap)
        guard !frames.isEmpty else { return }
        // Pixel-round each frame to whole physical pixels (HiDPI
        // crispness) on the active display's backing scale — after
        // gap (which introduces fractional points), before the AX
        // write. Kept out of AXGeom's generic setters so anchor-hide's
        // sub-pixel reveal coords aren't rounded (would break the
        // macOS clamp dodge).
        let scale = activeScale(near: rect)
        // Below this (≈1pt), treat the window as already at the
        // target and skip the AX write. pixel-rounding lands frames
        // on 0.5pt (Retina) boundaries so genuine targets compare
        // well within 1pt.
        let eps: CGFloat = 1.0

        if cached {
            // Live-resize-follow fast path. The per-tick AX-element lookup
            // (AXGeom.window) measured ~14ms/tick — the bulk of the
            // neighbour's "ワンテンポ遅れ" — so cache the element for the
            // drag (cachedFollowAX). No frame-match skip here: the upstream
            // 4pt dead-zone (RealWindowDrag) already drops no-op ticks, so
            // every cached tick is a real move; just write the current
            // target to the cached element. (An in-process last-applied
            // skip was tried but could desync from the window's real frame
            // and wrongly skip a needed write; the dead-zone makes it
            // unnecessary.) Writes stay SERIAL: the followers are usually
            // the same app, where AX writes serialise on that app's main
            // thread anyway, so concurrentPerform only adds overhead
            // (measured slower). The residual write time is the public-AX
            // ceiling — the app's own AX speed, which facet can't reduce.
            var applied = 0
            for (id, frame) in frames {
                if skip.contains(id) { continue }
                guard let ax = cachedFollowAX(id) else { continue }
                let r = frame.roundedToPhysicalPixels(scale: scale)
                AXGeom.setPosition(ax, r.origin)
                AXGeom.setSize(ax, r.size)
                applied += 1
            }
            Log.debug("native: \(label) live applied=\(applied) "
                + "skip=\(skip.count)")
            return
        }

        var applied = 0
        for (id, frame) in frames {
            // Live resize follow: the dragged window is being resized
            // natively by the user — skip it so we don't fight the OS.
            if skip.contains(id) { continue }
            guard let pid = catalog.pid(for: id) else { continue }
            guard let ax = AXGeom.window(
                for: CGWindowID(id.serverID),
                pid: pid_t(pid)) else { continue }
            let r = frame.roundedToPhysicalPixels(scale: scale)
            // Frame-match skip: if the window already sits at the
            // target, don't write. This stops facet's own setSize/
            // setPosition from re-firing kAXWindowResized/Moved →
            // re-tile loop (event-driven re-tile, D), and saves the
            // AX round-trip when nothing drifted.
            if let cur = AXGeom.position(ax), let sz = AXGeom.size(ax),
               abs(cur.x - r.minX) < eps, abs(cur.y - r.minY) < eps,
               abs(sz.width - r.width) < eps, abs(sz.height - r.height) < eps {
                continue
            }
            AXGeom.setPosition(ax, r.origin)
            AXGeom.setSize(ax, r.size)
            applied += 1
        }
        Log.debug("native: \(label) "
            + "frames=\(frames.count) applied=\(applied) "
            + "rect=\(rect)")
    }

    public func closeWindow(_ id: WindowID) {
        // pid comes from `catalog.windowMap[id]` — recorded at
        // reconcile time, so no fresh CGWindowList sweep is needed.
        // Failures here all surface in the errors stream so
        // `facet query` lastError tells the user *why* the
        // right-click "Close window" appeared to do nothing —
        // a debug-log-only failure would be invisible.
        guard let pid = catalog.pid(for: id) else {
            let msg = "closeWindow \(id.serverID): not in catalog "
                + "(window may have just opened — try again)"
            Log.debug("native: \(msg)")
            errorContinuation.yield(msg)
            return
        }
        guard let ax = AXGeom.window(
                for: CGWindowID(id.serverID), pid: pid_t(pid)) else {
            let msg = "closeWindow \(id.serverID): AX element "
                + "unavailable (app may have died, or has no AX)"
            Log.debug("native: \(msg)")
            errorContinuation.yield(msg)
            return
        }
        let pressed = AXGeom.closeButton(ax)
        Log.debug("native: closeWindow \(id.serverID) "
            + "pressed=\(pressed)")
        if !pressed {
            errorContinuation.yield(
                "closeWindow \(id.serverID): close button "
                + "missing or refused (app dialog intercepted?)")
        }
        // Best-effort eviction from catalog — the next event /
        // poll reconcile will fix it anyway if the app intercepted
        // (e.g. unsaved-changes dialog) and the window survives.
        if pressed { catalog.drop(id) }
        eventContinuation.yield(.refreshNeeded)
    }

    public func revealWindow(_ id: WindowID) {
        // Tree-click on a hidden row. Probe BOTH restore paths — each
        // no-ops when not applicable — rather than tracking whether the
        // window was Cmd+H'd or Cmd+M'd. The catalog re-attaches it to
        // the layout on the next reconcile (the AX deminiaturize/shown
        // event already nudged one). Memory: `facet-hide-reclaim-decisions`.
        guard let pid = catalog.pid(for: id) else {
            Log.debug("native: revealWindow \(id.serverID): not in catalog")
            return
        }
        // 1) Cmd+H app-hide → unhide the owning app (macOS has no
        //    per-window un-hide, so this reveals all its windows).
        NSRunningApplication(processIdentifier: pid_t(pid))?.unhide()
        // 2) Cmd+M minimize → clear kAXMinimized on the window.
        if let ax = AXGeom.window(for: CGWindowID(id.serverID),
                                  pid: pid_t(pid)) {
            AXGeom.setMinimized(ax, false)
        }
        // 3) Focus the restored window (backend-confirmed retry, like
        //    every other focus path here).
        Focus.assert(
            Window(id: id, pid: pid, appName: "", title: "",
                   isFocused: false, isFloating: false, frame: nil),
            backend: self)
        Log.debug("native: revealWindow \(id.serverID) "
            + "(unhide + unminimize + focus)")
        eventContinuation.yield(.refreshNeeded)
    }

    /// Animate (or instantly apply) the active workspace's reflow after
    /// a user action (master / orientation / float). Mirrors the retile
    /// path — animate when on, else snap — and owns the refresh yield.
    func reflowActive(rect: CGRect,
                              extra: (id: WindowID, target: CGRect)? = nil) {
        if config.effectiveAnimationsEnabled,
           animateRetile(workspace: catalog.activeIndex, rect: rect,
                         extra: extra) {
            return
        }
        if let extra, let ax = axWin(id: extra.id) {
            AXGeom.setPosition(ax, extra.target.origin)
            AXGeom.setSize(ax, extra.target.size)
        }
        applyLayout(workspace: catalog.activeIndex, rect: rect)
        eventContinuation.yield(.refreshNeeded)
    }

    /// The tiled neighbour of the focused window in `direction`, or nil
    /// at an edge / when there's nothing to step to (stack = one visible
    /// window, float = its own rects). Pure geometry (`nearestWindow`)
    /// over the active WS's tiled frames (②).
    private func directionalNeighbor(_ direction: Direction,
                                     rect: CGRect) -> WindowID? {
        guard let id = focusedWindow() else { return nil }
        let frames = targetFrames(for: catalog.activeIndex, in: rect)
        guard let here = frames[id] else { return nil }
        let others = frames.compactMap { kv -> (id: WindowID, frame: CGRect)? in
            kv.key == id ? nil : (id: kv.key, frame: kv.value)
        }
        return nearestWindow(to: here, among: others, direction: direction)
    }

    public func perform(_ action: WindowAction) {
        dispatchPrecondition(condition: .onQueue(cliQueue))   // P6
        // BSP: toggleFloat, toggleOrientation. Stack:
        // cycleStackNext, cycleStackPrev. Everything else
        // (master_stack / scrolling / toggleStack /
        // toggleFullscreen) is out of Phase γ scope and no-ops.
        let rect = activeDisplayRect()
        switch action {
        case .toggleFloat:
            guard let id = focusedWindow() else { return }
            catalog.toggleFloat(id, focused: id, in: rect)
            let nowFloating = catalog.isFloating(id)
            Log.debug("native: perform toggleFloat "
                + "\(id.serverID) → isFloating=\(nowFloating)")
            // Task 2: a user-toggled float lands centered on the active
            // display (current size preserved). Auto-floats (AX role,
            // sheets / dialogs) are not user-triggered and skip this —
            // the app's chosen position is left alone.
            var extra: (id: WindowID, target: CGRect)? = nil
            if nowFloating, let ax = axWin(id: id),
               let sz = AXGeom.size(ax) {
                let target = CGRect(
                    x: rect.midX - sz.width / 2,
                    y: rect.midY - sz.height / 2,
                    width: sz.width, height: sz.height)
                extra = (id, target)
            }
            reflowActive(rect: rect, extra: extra)
        case .toggleSticky:
            // Pin / unpin the focused window across every WS in this
            // mac desktop. Setting: catalog force-floats + park-exempts
            // it (it stays at its current frame). Clearing: catalog
            // un-floats + re-homes it as a tiled window of the active WS
            // (Q4). Either way the active WS reflows: setting fills the
            // gap the window left, clearing tiles the returning window.
            guard let id = focusedWindow() else { return }
            var extra: (id: WindowID, target: CGRect)? = nil
            if catalog.isSticky(id) {
                catalog.clearSticky(id, focused: id, in: rect)
            } else {
                // Center a *tiled* window as it becomes sticky: it's
                // about to float and would otherwise overlap whatever
                // reflows into its freed slot — same rule as
                // toggle-float ("a tiled window turning floating lands
                // centered"). A window ALREADY floating (PiP / timer /
                // music) keeps its position — pinning shouldn't teleport
                // it (POLA).
                let wasFloating = catalog.isFloating(id)
                catalog.setSticky(id)
                if !wasFloating, let ax = axWin(id: id),
                   let sz = AXGeom.size(ax) {
                    let target = CGRect(
                        x: rect.midX - sz.width / 2,
                        y: rect.midY - sz.height / 2,
                        width: sz.width, height: sz.height)
                    extra = (id, target)
                }
            }
            // Log the *actual* post-state — setSticky no-ops for a
            // window not yet in `windowMap`, so the intended flag would
            // lie about the outcome.
            Log.debug("native: perform toggleSticky "
                + "\(id.serverID) → isSticky=\(catalog.isSticky(id))")
            reflowActive(rect: rect, extra: extra)
        case .toggleOrientation:
            // bsp-only: rotate the focused window's parent split. The
            // master engines pick their edge directly via
            // `--layout master-EDGE` (M9-2), so there's no orientation
            // knob left to flip here.
            guard catalog.mode(of: catalog.activeIndex) == "bsp",
                  let id = focusedWindow() else { return }
            catalog.toggleOrientation(of: id)
            Log.debug("native: perform toggleOrientation "
                + "\(id.serverID)")
            reflowActive(rect: rect)
        case .cycleStackNext, .cycleStackPrev:
            // Cycle is per-active-WS; no need for `focusedWindow`
            // — the catalog owns "who's the current top" via the
            // stack-order array, not via OS focus.
            let direction: WorkspaceCatalog.CycleDirection =
                action == .cycleStackNext ? .next : .prev
            if config.effectiveAnimationsEnabled {
                // 枠 E: slide the old top out / next top in.
                animateStackCycle(direction: direction, rect: rect)
            } else {
                let newTop = catalog.cycleStack(
                    workspace: catalog.activeIndex, direction: direction)
                Log.debug("native: perform \(action) → newTop="
                    + "\(newTop?.serverID.description ?? "nil")")
                if newTop != nil {
                    applyStack(workspace: catalog.activeIndex, rect: rect)
                    eventContinuation.yield(.refreshNeeded)
                }
            }
        case .promoteToMaster:
            // master-stack: move the focused window to the
            // master slot (index 0 of the WS's shared order).
            guard let id = focusedWindow() else { return }
            let moved = catalog.promoteToMaster(
                id, workspace: catalog.activeIndex)
            Log.debug("native: perform promoteToMaster "
                + "\(id.serverID) moved=\(moved)")
            if moved {
                reflowActive(rect: rect)
            }
        case .growMaster, .shrinkMaster:
            // Master-ratio nudge — only meaningful for the master
            // engines; other modes ignore the knob.
            guard hasMasterKnob(catalog.activeIndex) else { return }
            let delta: CGFloat = action == .growMaster ? 0.05 : -0.05
            if catalog.adjustMasterRatio(
                workspace: catalog.activeIndex, delta: delta) {
                reflowActive(rect: rect)
            }
        case .incMaster, .decMaster:
            guard hasMasterKnob(catalog.activeIndex) else { return }
            let delta = action == .incMaster ? 1 : -1
            if catalog.adjustMasterCount(
                workspace: catalog.activeIndex, delta: delta) {
                reflowActive(rect: rect)
            }
        case .focusDir(let dir):
            // ② Directional focus: pick the tiled neighbour on that side
            // and assert focus (no layout change). Edge / stack (single
            // visible) → nearestWindow returns nil → no-op.
            guard let target = directionalNeighbor(dir, rect: rect),
                  let win = enumerateCGWindows().first(where: { $0.id == target })
            else { return }
            Focus.assert(win, backend: self)
        case .moveDir(let dir):
            // ② Directional move: swap the focused window with the tiled
            // neighbour on that side (yabai --swap). Edge → no-op.
            guard let id = focusedWindow(),
                  let target = directionalNeighbor(dir, rect: rect) else { return }
            swapWindows(id, target)
        // out-of-scope / future cases — no-op, but listed explicitly
        // so the compiler enforces a handling decision on every
        // future enum addition.
        case .toggleFullscreen,
             .swapMasterStack,
             .toggleStack,
             .centerColumn, .snapStrip:
            break
        }
    }

    /// Whether the WS's mode reads the master ratio / count knobs — true
    /// exactly for the master-stack engines (`master-left` …
    /// `master-center`), which is what `LayoutEngine.hasMaster` reports.
    /// Data-driven so new master engines need no edit here. Other modes
    /// (bsp / stack / grid / spiral / float) ignore the knobs, so master
    /// adjustments no-op there.
    func hasMasterKnob(_ n1Based: Int) -> Bool {
        LayoutRegistry.engine(named: catalog.mode(of: n1Based))?.hasMaster ?? false
    }

    /// Apply the workspace's mode-specific layout (tile / stack /
    /// no-op). Single dispatch site — every callsite that mutates
    /// the catalog and might need to push fresh frames through AX
    /// (refresh / switch / move / setMode / retile / perform)
    /// funnels through here.
    func applyLayout(workspace n1Based: Int, rect: CGRect,
                             skip: Set<WindowID> = [], cached: Bool = false) {
        // Tag mode (M11-3): there's no per-workspace tree — tile the
        // visible lens union with the one global engine. `n1Based` is
        // ignored (every applyLayout call routes here in tag mode).
        if catalog.grouping == .tag {
            applyFrames(catalog.tagUnionFrames(in: rect),
                        label: "tag-union", rect: rect, skip: skip,
                        cached: cached)
            return
        }
        let mode = catalog.mode(of: n1Based)
        switch mode {
        case "bsp":   applyTile(workspace: n1Based, rect: rect, skip: skip,
                                cached: cached)
        case "stack": applyStack(workspace: n1Based, rect: rect)
        default:
            if LayoutRegistry.engine(named: mode) != nil {
                applyEngine(workspace: n1Based, rect: rect, skip: skip,
                            cached: cached)
            }
        }
    }

    public func windowMenu(mode: String, floating: Bool,
                           isMaster: Bool,
                           windowCount: Int,
                           isSticky: Bool) -> [WindowMenuItem] {
        // Menu items per layout mode (Phase γ), gated by the window's
        // actual state so master vs non-master (and a lone stack
        // window) get the right menu — no dead items. Floating windows
        // only get Unfloat + Close (tiling actions don't apply).
        // `icon` / `section` (item 4 + 7 + 12): tiling ops group under
        // "Layout", window-state + destructive ops under "Action" (the view
        // slots the per-window "Tag" between them). The section names drive
        // the dim group headers the popup menu inserts.
        var items: [WindowMenuItem] = []
        if mode == "bsp", !floating {
            items.append(.init("Toggle orientation", [.toggleOrientation],
                               icon: "SF:arrow.triangle.2.circlepath",
                               section: "Layout"))
        }
        // Cycling needs at least two windows to rotate between.
        if mode == "stack", !floating, windowCount >= 2 {
            items.append(.init("Next stack window", [.cycleStackNext],
                               icon: "SF:chevron.down", section: "Layout"))
            items.append(.init("Previous stack window", [.cycleStackPrev],
                               icon: "SF:chevron.up", section: "Layout"))
        }
        if LayoutRegistry.engine(named: mode)?.hasMaster == true, !floating {
            // "Promote to master" is meaningless for the window that
            // already holds the master slot.
            if !isMaster {
                items.append(.init("Promote to master", [.promoteToMaster],
                                   icon: "SF:crown", section: "Layout"))
            }
            items.append(.init("Wider master", [.growMaster],
                               icon: "SF:arrow.left.and.right",
                               section: "Layout"))
            items.append(.init("Narrower master", [.shrinkMaster],
                               icon: "SF:arrow.right.and.line.vertical.and.arrow.left",
                               section: "Layout"))
            items.append(.init("More masters", [.incMaster],
                               icon: "SF:plus", section: "Layout"))
            items.append(.init("Fewer masters", [.decMaster],
                               icon: "SF:minus", section: "Layout"))
        }
        // A sticky window is always floating, and float-exit =
        // sticky-exit, so "Unfloat" and "Unstick" would do the same
        // thing — show only the clearer "Unstick" and skip "Sticky"
        // (it already is). Any other window gets Float/Unfloat plus a
        // "Sticky" entry (setSticky force-floats a tiled window).
        if isSticky {
            items.append(.init("Unstick", [.toggleSticky],
                               icon: "SF:pin.slash", section: "Action"))
        } else {
            items.append(.init(floating ? "Unfloat" : "Float", [.toggleFloat],
                               icon: floating ? "SF:pip.exit" : "SF:macwindow",
                               section: "Action"))
            items.append(.init("Sticky", [.toggleSticky],
                               icon: "SF:pin", section: "Action"))
        }
        items.append(.init("Close window", [], close: true,
                           icon: "SF:xmark", section: "Action"))
        return items
    }
}
