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
    func targetFrames(for n1Based: Int, in rect: CGRect)
        -> [WindowID: CGRect]
    {
        let mode = catalog.mode(of: n1Based)
        switch mode {
        case "bsp":
            return catalog.tiledFrames(for: n1Based, in: rect)
        case "stack":
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
    /// must still settle (its outgoing windows have to be recorded
    /// parked before the catalog mutates again).
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
        // Honour the system "Reduce motion" setting — fall back to the
        // instant path so motion-sensitive users aren't animated at.
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
        slideAnims = []
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
            slideAnims.append((ax, WindowSlide(id: id, from: start, to: f)))
        }

        // Outgoing: capture true current frame, slide off the far edge.
        var outOrigin: [WindowID: CGPoint] = [:]
        for ref in toPark {
            guard catalog.shouldParkAnchor(ref.id), let ax = axWin(ref),
                  let p = AXGeom.position(ax), let sz = AXGeom.size(ax) else { continue }
            outOrigin[ref.id] = p
            let from = CGRect(origin: p, size: sz)
            let to = CGRect(x: p.x - enterDx, y: p.y, width: sz.width, height: sz.height)
            slideAnims.append((ax, WindowSlide(id: ref.id, from: from, to: to)))
        }

        guard !slideAnims.isEmpty else { return false }

        // Settle: authoritative final state + park bookkeeping. Runs once
        // (on completion or interrupt). Uses the *captured* outgoing
        // origins so a later switch-back restores to the real position,
        // not the slid-off-screen one.
        let settle: () -> Void = { [weak self] in
            guard let self else { return }
            self.slideAnims = []
            self.applyLayout(workspace: newActive, rect: rect)
            for ref in toPark {
                guard let orig = outOrigin[ref.id], let ax = self.axWin(ref)
                else { continue }
                let scr = Displays.containing(orig)
                self.catalog.markAnchorParked(ref.id, originalPosition: orig)
                AXGeom.setPosition(ax, CGPoint(x: scr.maxX - 1, y: scr.maxY - 1))
            }
            if autoFocus { self.applyAutoFocus(newActiveWS: newActive) }
            self.eventContinuation.yield(.refreshNeeded)
        }

        slideIsRetile = false
        startSlideDriver(settle)
        Log.debug("native: animateSwitch \(oldActive)->\(newActive) "
            + "anims=\(slideAnims.count) dir=\(Int(dir))")
        return true
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
        slideAnims = []
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
            slideAnims.append((ax, WindowSlide(id: id, from: from, to: snapped)))
        }
        for (id, raw) in targets where !skipAnimation.contains(id) {
            append(id, raw)
        }
        if let extra { append(extra.id, extra.target) }
        guard !slideAnims.isEmpty else { return false }
        let settle: () -> Void = { [weak self] in
            guard let self else { return }
            self.slideAnims = []
            self.applyLayout(workspace: n1Based, rect: rect)
            if let extra {
                // Floating windows live outside the layout — settle their
                // final frame explicitly so a missed mid-tween write can't
                // leave them subtly off.
                if let ax = self.axWin(id: extra.id) {
                    AXGeom.setPosition(ax, extra.target.origin)
                    AXGeom.setSize(ax, extra.target.size)
                }
            }
            self.eventContinuation.yield(.refreshNeeded)
        }
        slideIsRetile = true
        startSlideDriver(settle)
        Log.debug("native: animateRetile WS \(n1Based) anims=\(slideAnims.count)"
            + (extra != nil ? " (+extra)" : ""))
        return true
    }

    /// 枠 E: animate a stack cycle as a one-window slide — the old top
    /// exits one edge, the next window enters from the opposite edge
    /// (the others stay parked); direction picks the axis. Always applies
    /// the cycle; settles via applyStack (newTop fills, others park), and
    /// falls back to an instant applyStack when it can't animate.
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
        slideAnims = []
        // Old top: slide off the near edge (size constant → translation).
        slideAnims.append((oldAx, WindowSlide(
            id: oldTop,
            from: CGRect(origin: oldPos, size: oldSize),
            to: CGRect(x: oldPos.x - dx, y: oldPos.y,
                       width: oldSize.width, height: oldSize.height))))
        // New top: un-park, place off the far edge at full size, slide in.
        catalog.clearParkedState(of: newTop)
        AXGeom.setSize(newAx, r.size)
        let start = CGRect(x: r.minX + dx, y: r.minY,
                           width: r.width, height: r.height)
        AXGeom.setPosition(newAx, start.origin)
        slideAnims.append((newAx, WindowSlide(id: newTop, from: start, to: r)))

        let settle: () -> Void = { [weak self] in
            guard let self else { return }
            self.slideAnims = []
            self.applyStack(workspace: active, rect: rect)
            self.eventContinuation.yield(.refreshNeeded)
        }
        slideIsRetile = false   // park bookkeeping in settle → settle on interrupt
        startSlideDriver(settle)
    }
}
