// 枠 E: workspace-switch slide animation — per-frame driver
// (CADisplayLink / Timer), easing, and the animate* entry points
// for switch / retile / stack-cycle. Extracted unchanged from
// NativeAdapter.swift (#182 phase 4) — same-module extension, no
// logic change. Stored state (slide clock / anims / hints) stays on
// the primary declaration (NativeAdapter.swift).

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import QuartzCore
import FacetAccessibility
import FacetCore

/// NSObject shim so a `CADisplayLink` (target/selector only on macOS)
/// can drive `NativeAdapter.slideTick`, which isn't an NSObject. The
/// adapter owns the shim; the back-ref is weak.
final class SlideTicker: NSObject {
    weak var adapter: NativeAdapter?
    init(_ adapter: NativeAdapter) { self.adapter = adapter; super.init() }
    // `Any` (not CADisplayLink) so the signature stays available on
    // macOS 13; the link arg is unused. The 14+ display link calls it.
    @objc func tick(_ sender: Any) { adapter?.slideTick() }
}

extension NativeAdapter {
    // MARK: - 枠 E: workspace-switch slide animation (Phase 1)

    /// AX element for a managed window (pid via the catalog).
    func axWin(id: WindowID) -> AXUIElement? {
        guard let pid = catalog.pid(for: id) else { return nil }
        return AXGeom.window(for: CGWindowID(id.serverID), pid: pid_t(pid))
    }
    func axWin(_ ref: WindowRef) -> AXUIElement? {
        AXGeom.window(for: CGWindowID(ref.id.serverID), pid: pid_t(ref.pid))
    }

    /// Visible tiled targets for a workspace (bsp tree / engine / stack
    /// top). Floating windows aren't here — they restore to their
    /// recorded original position (handled in `animateSwitch`).
    ///
    /// EX-0.2 fix: the section-lens union branch mirrors
    /// `applyLayout` so the animated paths (`animateSwitch`, `animateRetile`,
    /// `directionalNeighbor`) compute the SAME frame set as the instant path.
    /// Without this the animated path was lens-blind: it computed per-WS frames
    /// while `applyLayout` tiled the cross-workspace union, so with
    /// `[animation] enabled=true` AND an active section lens the two paths
    /// disagreed. Self-corrects via settle reconcile (animation is opt-in), but
    /// violates トミー's 負債を残さない principle. The branch ignores `n1Based`
    /// (the union spans all workspaces), symmetric with `applyLayout`.
    func targetFrames(for n1Based: Int, in rect: CGRect)
        -> [WindowID: CGRect]
    {
        // Section-lens union (EX-1 exclusive model): tile the cross-workspace
        // in-lens set with the lens's stateless engine when active, matching
        // `applyLayout`.
        if let label = catalog.activeSectionLens {
            // EX-0.3: resolvedLensLayout honours the runtime override (activeSectionLensLayout).
            return catalog.sectionLensUnionFrames(layout: resolvedLensLayout(forLabel: label),
                                                  in: rect)
        }
        let mode = catalog.mode(of: n1Based)
        switch mode {
        case StatefulMode.bsp:
            return catalog.tiledFrames(for: n1Based, in: rect)
        case StatefulMode.stack:
            guard let top = catalog.stackOrder(of: n1Based).first
            else { return [:] }
            return [top: rect]
        default:
            guard LayoutRegistry.engine(named: mode) != nil else { return [:] }
            return catalog.engineFrames(for: n1Based, in: rect)
        }
    }

    /// Stop the per-frame driver (display link / timer). Doesn't settle.
    private func stopSlideClock() {
        if #available(macOS 14.0, *), let link = displayLink as? CADisplayLink {
            link.invalidate()
        }
        displayLink = nil
        slideTimer?.invalidate()
        slideTimer = nil
    }

    /// Run the in-flight slide's settle now (on normal completion, or a
    /// hard finish that must apply the final state + park bookkeeping).
    private func finishSlideIfRunning() {
        guard let finish = slideFinish else { return }
        stopSlideClock()
        slideStart = nil
        slideFinish = nil
        finish()
    }

    /// Interrupt the in-flight slide for a *new* transition. A retile
    /// carries no park bookkeeping, so just drop it — the windows stay
    /// where they are mid-slide and the new animation redirects from
    /// their current positions (no jump to the old target). A switch
    /// settles its (now AX-only) finish so its outgoing windows land at
    /// their anchor sliver before the new slide starts.
    ///
    /// P6: called ONLY from `startSlide` (main), which sets
    /// `slideInProgress = true` immediately after — so the drop branch
    /// deliberately doesn't reset that flag (it would be re-set on the
    /// next line). Never call this from a cliQueue command body; the
    /// slide clock is main-confined.
    func cancelSlideForRetarget() {
        guard slideFinish != nil else { return }
        if slideIsRetile {
            stopSlideClock()
            slideAnims = []
            slideStart = nil
            slideFinish = nil
        } else {
            finishSlideIfRunning()
        }
    }

    /// One animation frame: advance progress and write each window's
    /// origin. Runs on the main runloop (CADisplayLink on macOS 14+,
    /// else a 120 Hz timer). fileprivate so the SlideTicker shim can
    /// call it; a late tick after settle no-ops on the nil slideStart.
    fileprivate func slideTick() {
        guard let begin = slideStart else { return }
        let raw = min(1.0, -begin.timeIntervalSinceNow / slideDuration)
        let e = slideCurve(raw)
        // AX is thread-safe per element; we vouch for the fan-out.
        nonisolated(unsafe) let anims = slideAnims
        // Many windows: fan out the per-frame writes so the serial sum
        // doesn't blow the frame budget. Few windows: stay serial.
        // setSize only when the tween actually resizes (WS-switch slides
        // keep size constant — pure translation).
        func write(_ a: (ax: AXUIElement, slide: WindowSlide)) {
            let fr = a.slide.frame(atEased: e)
            AXGeom.setPosition(a.ax, fr.origin)
            if a.slide.resizes { AXGeom.setSize(a.ax, fr.size) }
        }
        if anims.count >= 6 {
            DispatchQueue.concurrentPerform(iterations: anims.count) { i in
                write(anims[i])
            }
        } else {
            for a in anims { write(a) }
        }
        if raw >= 1.0 { finishSlideIfRunning() }
    }

    /// Curve + duration for the in-flight animation. `FACET_ANIM_CURVE`
    /// (spring | silky | snappy | cubic) is a dev override for A/B'ing
    /// the feel; default = ease-out cubic at the configured duration.
    private func resolveAnimPreset()
        -> (curve: (Double) -> Double, duration: TimeInterval)
    {
        let env = ProcessInfo.processInfo.environment
        // Curve: env (dev A/B) → config → default. "random" → pick one
        // per transition.
        var name = env["FACET_ANIM_CURVE"] ?? config.effectiveAnimationCurve
        if name == "random" {
            name = ["cubic", "spring", "silky", "snappy"].randomElement() ?? "cubic"
        }
        // Duration: env override → config (if set, clamped) → per-curve default.
        func ms(_ perCurveMs: Double) -> TimeInterval {
            if let e = Double(env["FACET_ANIM_MS"] ?? "") { return e / 1000 }
            if let c = config.animationDurationMs {
                return Double(min(800, max(80, c))) / 1000
            }
            return perCurveMs / 1000
        }
        switch name {
        case "spring":
            // FACET_SPRING_ZETA: lower = bouncier (more overshoot).
            let z = Double(env["FACET_SPRING_ZETA"] ?? "") ?? 0.5
            return ({ SlideCurve.spring($0, zeta: z) }, ms(420))
        case "silky":  return (SlideCurve.easeInOutCubic, ms(420))
        case "snappy": return (SlideCurve.easeOutQuint, ms(220))
        default:       return (SlideCurve.easeOutCubic, ms(280))
        }
    }

    /// Start the per-frame driver for an already-populated `slideAnims`.
    /// Prefers a vsync CADisplayLink (macOS 14+); Timer fallback on 13.
    /// `settle` runs once on completion (or interrupt via
    /// finishSlideIfRunning).
    private func startSlideDriver(_ settle: @escaping () -> Void) {
        let preset = resolveAnimPreset()
        slideCurve = preset.curve
        slideStart = Date()
        slideDuration = preset.duration
        slideFinish = settle
        if #available(macOS 14.0, *), let screen = NSScreen.main {
            let link = screen.displayLink(target: slideTicker,
                                          selector: #selector(SlideTicker.tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) {
                [weak self] _ in self?.slideTick()
            }
            RunLoop.main.add(timer, forMode: .common)
            slideTimer = timer
        }
    }

    /// Phase 1 of 枠 E: slide the directional filmstrip on a workspace
    /// switch. Incoming windows enter from one edge (sized off-screen
    /// first, so visible motion is pure translation); outgoing exit the
    /// opposite edge; the index delta picks the direction. The real
    /// park/tile bookkeeping happens in the settle closure (run on
    /// completion or on interrupt). Returns false when nothing is
    /// visible to move, so the caller falls back to the instant path.
    func animateSwitch(toPark: [WindowRef], toRestore: [WindowRef],
                               oldActive: Int, newActive: Int,
                               directionHint: CGFloat?,
                               rect: CGRect, autoFocus: Bool) -> Bool {
        // P6: runs on `cliQueue` (the command body). The catalog is
        // committed HERE; the animation that follows is a purely cosmetic
        // tween that never touches catalog again. Honour "Reduce motion" —
        // fall back to the caller's instant path.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return false
        }
        let screen = Displays.containing(CGPoint(x: rect.midX, y: rect.midY))
        let dir: CGFloat = directionHint ?? (newActive > oldActive ? 1 : -1)
        let enterDx = dir * screen.width   // incoming start offset (off entry edge)
        let scale = activeScale(near: rect)

        // Incoming: tiled/engine/stack targets + floating-at-original.
        var targets = targetFrames(for: newActive, in: rect)
        for ref in toRestore where targets[ref.id] == nil {
            guard let orig = catalog.originalPositions[ref.id],
                  let ax = axWin(ref), let sz = AXGeom.size(ax) else { continue }
            targets[ref.id] = CGRect(origin: orig, size: sz)
        }
        // Build the visual plan as a LOCAL value + commit catalog HERE
        // (clearParkedState for incoming, markAnchorParked for outgoing).
        var anims: [(ax: AXUIElement, slide: WindowSlide)] = []
        for (id, raw) in targets {
            guard let ax = axWin(id: id) else { continue }
            let f = raw.roundedToPhysicalPixels(scale: scale)
            // We own this window's geometry now — clear its parked flag.
            catalog.clearParkedState(of: id)
            AXGeom.setSize(ax, f.size)                       // off-screen resize
            // from/to share the final size → pure translation (no setSize
            // per frame), sliding in from off the entry edge.
            let start = CGRect(x: f.origin.x + enterDx, y: f.origin.y,
                               width: f.width, height: f.height)
            AXGeom.setPosition(ax, start.origin)
            anims.append((ax, WindowSlide(id: id, from: start, to: f)))
        }

        // Outgoing: capture true current frame, slide off the far edge, and
        // record the final anchor-sliver snap for the AX-only settle. Park
        // bookkeeping (markAnchorParked) is committed NOW with the real
        // pre-slide origin, so a later switch-back restores correctly.
        var parkSnaps: [(ax: AXUIElement, at: CGPoint)] = []
        for ref in toPark {
            guard catalog.shouldParkAnchor(ref.id), let ax = axWin(ref),
                  let p = AXGeom.position(ax), let sz = AXGeom.size(ax) else { continue }
            let from = CGRect(origin: p, size: sz)
            let to = CGRect(x: p.x - enterDx, y: p.y, width: sz.width, height: sz.height)
            anims.append((ax, WindowSlide(id: ref.id, from: from, to: to)))
            catalog.markAnchorParked(ref.id, originalPosition: p)
            parkSnaps.append((ax, Displays.anchorSliver(near: p)))
        }

        guard !anims.isEmpty else { return false }

        // Focus the destination now — the animation is purely cosmetic from
        // here, so there's no reason to defer focus to the settle.
        if autoFocus { applyAutoFocus(newActiveWS: newActive) }

        let count = anims.count
        // Hand the value plan to the main-confined driver. The AX elements
        // inside are thread-safe per element (we vouch, as `slideTick`
        // does), and the cliQueue side never touches `anims`/`parkSnaps`
        // after this send.
        nonisolated(unsafe) let plan = anims
        nonisolated(unsafe) let snaps = parkSnaps
        DispatchQueue.main.async { [weak self] in
            self?.startSlide(anims: plan, parkSnaps: snaps, isRetile: false)
        }
        Log.debug("native: animateSwitch \(oldActive)->\(newActive) "
            + "anims=\(count) dir=\(Int(dir))")
        return true
    }

    /// P6: the main-confined half of every slide. Hopped (once) from the
    /// cliQueue command after it committed the catalog, it stops any prior
    /// slide, records the *value* plan, and drives the per-frame tween. The
    /// settle is AX-ONLY: it snaps parked windows to their anchor sliver
    /// (`parkSnaps`) and any window needing an exact final frame
    /// (`frameSnaps`), clears the in-progress flag, and yields a refresh —
    /// it never touches the catalog (already committed on cliQueue). The
    /// slide clock (anims / start / timer / link / finish / isRetile /
    /// inProgress) is touched ONLY here, in `slideTick`, and in the settle,
    /// all on the main runloop. Like `startSlideDriver` / `slideTick` it is
    /// a plain (nonisolated) method invoked ON main via `DispatchQueue.main`
    /// — the convention, not the type system, keeps it main-confined.
    func startSlide(anims: [(ax: AXUIElement, slide: WindowSlide)],
                    parkSnaps: [(ax: AXUIElement, at: CGPoint)] = [],
                    frameSnaps: [(ax: AXUIElement, frame: CGRect)] = [],
                    isRetile: Bool) {
        // Land (switch) or drop (retile) any in-flight slide first. Its
        // settle is AX-only now, so running it here on main is safe.
        cancelSlideForRetarget()
        slideAnims = anims
        slideIsRetile = isRetile
        slideInProgress = true
        startSlideDriver { [weak self] in
            guard let self else { return }
            self.slideAnims = []
            for (ax, at) in parkSnaps { AXGeom.setPosition(ax, at) }
            for (ax, fr) in frameSnaps {
                AXGeom.setPosition(ax, fr.origin)
                AXGeom.setSize(ax, fr.size)
            }
            self.slideInProgress = false
            self.eventContinuation.yield(.refreshNeeded)
        }
    }

    /// Phase 2 of 枠 E: animate a same-mode re-tile / layout change as an
    /// in-place reflow — every visible window tweens its full frame
    /// (position + size) from where it sits now to its new tiled frame.
    /// All windows stay on-screen (no off-screen trick), so this is the
    /// resize-bearing path. Returns false (caller does the instant apply)
    /// when reduce-motion is set or nothing actually moves.
    ///
    /// `extra` adds one off-layout window (e.g. just-floated) to the
    /// same animation cycle so its move stays coordinated with the
    /// retile of the remaining tiled windows.
    ///
    /// `skipAnimation` snaps the listed ids straight to their tile
    /// frame instead of including them in the slide. Used by the
    /// open-reflow gate so a brand-new window appears at its tile
    /// slot (rather than gliding from the app's wild initial
    /// position); the surrounding windows still animate.
    func animateRetile(workspace n1Based: Int, rect: CGRect,
                               extra: (id: WindowID, target: CGRect)? = nil,
                               skipAnimation: Set<WindowID> = []) -> Bool
    {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return false
        }
        let scale = activeScale(near: rect)
        let targets = targetFrames(for: n1Based, in: rect)
        // P6: build the plan as a LOCAL value — no catalog mutation here
        // (the caller already committed the layout/mode change). The tween
        // lands each window exactly at its `to`; the settle is AX-only.
        var anims: [(ax: AXUIElement, slide: WindowSlide)] = []
        func append(_ id: WindowID, _ to: CGRect) {
            guard let ax = axWin(id: id), let p = AXGeom.position(ax),
                  let sz = AXGeom.size(ax) else { return }
            let snapped = to.roundedToPhysicalPixels(scale: scale)
            let from = CGRect(origin: p, size: sz)
            if abs(from.minX - snapped.minX) < 1,
               abs(from.minY - snapped.minY) < 1,
               abs(from.width - snapped.width) < 1,
               abs(from.height - snapped.height) < 1 {
                return
            }
            anims.append((ax, WindowSlide(id: id, from: from, to: snapped)))
        }
        for (id, raw) in targets where !skipAnimation.contains(id) {
            append(id, raw)
        }
        if let extra { append(extra.id, extra.target) }
        guard !anims.isEmpty else { return false }
        // Floating windows live outside the layout — settle their final
        // frame explicitly (AX-only) so a missed mid-tween write can't
        // leave them subtly off.
        var frameSnaps: [(ax: AXUIElement, frame: CGRect)] = []
        if let extra, let ax = axWin(id: extra.id) {
            frameSnaps.append((ax, extra.target))
        }
        let count = anims.count
        let hasExtra = extra != nil
        nonisolated(unsafe) let plan = anims
        nonisolated(unsafe) let snaps = frameSnaps
        DispatchQueue.main.async { [weak self] in
            self?.startSlide(anims: plan, frameSnaps: snaps, isRetile: true)
        }
        Log.debug("native: animateRetile WS \(n1Based) anims=\(count)"
            + (hasExtra ? " (+extra)" : ""))
        return true
    }

    /// 枠 E: animate a stack cycle as a one-window slide — the old top
    /// exits one edge, the next window enters from the opposite edge
    /// (the others stay parked); direction picks the axis. P6: the cycle's
    /// catalog state (park old top / un-park new top) is committed HERE on
    /// cliQueue; the AX-only settle snaps the demoted top to its sliver and
    /// the new top to the exact rect. Falls back to an instant `applyStack`
    /// when it can't animate.
    func animateStackCycle(direction: WorkspaceCatalog.CycleDirection,
                                   rect: CGRect) {
        let active = catalog.activeIndex
        let oldTop = catalog.stackOrder(of: active).first
        let newTop = catalog.cycleStack(workspace: active, direction: direction)
        Log.debug("native: animateStackCycle \(direction) "
            + "old=\(oldTop?.serverID.description ?? "nil") "
            + "new=\(newTop?.serverID.description ?? "nil")")
        guard let newTop, let oldTop, newTop != oldTop,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let oldAx = axWin(id: oldTop), let newAx = axWin(id: newTop),
              let oldPos = AXGeom.position(oldAx), let oldSize = AXGeom.size(oldAx)
        else {
            applyStack(workspace: active, rect: rect)
            eventContinuation.yield(.refreshNeeded)
            return
        }
        let r = rect.roundedToPhysicalPixels(scale: activeScale(near: rect))
        let dx = (direction == .next ? 1 : -1) * rect.width
        var anims: [(ax: AXUIElement, slide: WindowSlide)] = []
        // Old top: slide off the near edge (size constant → translation),
        // then park (catalog commit now; AX sliver snap in the settle).
        anims.append((oldAx, WindowSlide(
            id: oldTop,
            from: CGRect(origin: oldPos, size: oldSize),
            to: CGRect(x: oldPos.x - dx, y: oldPos.y,
                       width: oldSize.width, height: oldSize.height))))
        catalog.markAnchorParked(oldTop, originalPosition: oldPos)
        let parkSnaps = [(ax: oldAx, at: Displays.anchorSliver(near: oldPos))]
        // New top: un-park, place off the far edge at full size, slide in.
        catalog.clearParkedState(of: newTop)
        AXGeom.setSize(newAx, r.size)
        let start = CGRect(x: r.minX + dx, y: r.minY,
                           width: r.width, height: r.height)
        AXGeom.setPosition(newAx, start.origin)
        anims.append((newAx, WindowSlide(id: newTop, from: start, to: r)))
        let frameSnaps = [(ax: newAx, frame: r)]

        nonisolated(unsafe) let plan = anims
        nonisolated(unsafe) let pSnaps = parkSnaps
        nonisolated(unsafe) let fSnaps = frameSnaps
        DispatchQueue.main.async { [weak self] in
            self?.startSlide(anims: plan, parkSnaps: pSnaps,
                             frameSnaps: fSnaps, isRetile: false)
        }
    }
}
