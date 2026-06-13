// Shared neon-border driver — the THIN per-surface shell over sill's pure
// `resolveBorder`. Holds the `[border]` config + this surface's flash cell +
// an independent time origin, and drives one 30 Hz timer; the owning view
// renders the resolved `color` / `width` / glow in whatever way suits it — a
// CALayer (tree panel, grid overlay) via `apply(to:)`, or a Core-Graphics
// stroke (rail strip) by reading `color` / `width` in `draw(_:)`. The owner
// supplies `onRepaint` (set the layer, or `needsDisplay = true`).
//
// The animation MATH — width breathing, the 5-blink flash burst, and the
// cycle / rainbow / steady color resolve — lives in sill's CLOCKLESS
// `Effects.resolveBorder` / `rollFlash`, shared byte-for-byte with halo (the
// formerly-duplicated `BorderFX` animator, reconciled into one pure function).
// This driver keeps only what is genuinely app-side: the redraw timer, the
// `NSColor` materialization, the per-surface `pal.primary` "off" fallback, and
// the CALayer glow compositing (halo's `NSShadow` glow is a different model).
//
// One instance per view, each with its OWN `epoch`, so the three surfaces
// animate on independent phases (PR-B's intentional desync) — and `configure`
// never touches it, so an unrelated save doesn't restart the cycle.

import AppKit
import Effects
import PaletteKit
import QuartzCore   // CACurrentMediaTime — the shared border clock

@MainActor
public final class BorderFX {

    // Config (from `[border]`), materialized to sill's pure inputs.
    private var fx: EffectSpec?
    private var glowOn = false
    private var baseW: Double = 1.5
    private var cycleSeconds: Double = 6
    private var minW: Double?
    private var maxW: Double?
    /// Continuously loop a non-rainbow effect's color through its own flash
    /// palette (over `cycleSeconds`). On when `[border] cycle-seconds` is
    /// explicitly set; rainbow cycles regardless.
    private var cycleColors = false

    /// This surface's flash burst — pre-rolled on a WS-switch, decayed by
    /// wall-clock. nil = not flashing. Per-instance so each surface flashes
    /// independently.
    private var flashState: FlashState?
    /// This surface's time origin. `now` is measured from here so the three
    /// surfaces stay on independent phases AND `configure` doesn't reset the
    /// cycle. Both the cycle phase and the flash decay read this one clock.
    private let epoch = CACurrentMediaTime()
    private var now: Double { CACurrentMediaTime() - epoch }

    private var timer: Timer?

    /// Called on every tick + on configure / flash. The owner repaints:
    /// `apply(to: layer)` for a CALayer, or `needsDisplay = true` for a
    /// draw()-based view.
    public var onRepaint: (() -> Void)?

    /// Per-surface palette (PR-B). The owner (PanelHost / GridView / RailView)
    /// wires its surface box right after construction; the "off" fallback
    /// color reads `pal.primary` through it.
    public var paletteBox: PaletteBox!
    private var pal: ResolvedPalette { paletteBox.pal }

    public init() {}

    /// Push the `[border]` config. `effectName == "off"` (or unknown) leaves
    /// `active == false`.
    public func configure(effectName: String, glow: Bool, width: CGFloat,
                          cycleSeconds cs: CGFloat, cycleColors cc: Bool,
                          minWidth: CGFloat?, maxWidth: CGFloat?) {
        fx = borderEffectFor(effectName)
        glowOn = glow && fx != nil
        baseW = Double(width)
        cycleSeconds = max(1, Double(cs))
        cycleColors = cc
        minW = minWidth.map(Double.init)
        maxW = maxWidth.map(Double.init)
        updateTimer()
        onRepaint?()
    }

    /// Whether an effect is active (vs "off"). Grid / rail draw a border only
    /// when active; the tree panel draws a plain accent border even when off
    /// (so `color` falls back to `pal.primary`).
    public var active: Bool { fx != nil }
    public var glowEnabled: Bool { glowOn }

    /// The current resolved frame — sill's pure animator sampled at `now`.
    private func frame() -> BorderFrame {
        resolveBorder(spec: fx, baseWidth: baseW, minWidth: minW, maxWidth: maxW,
                      cycleSeconds: cycleSeconds, cycleColors: cycleColors,
                      now: now, flash: flashState)
    }

    /// Materialize sill's `BorderColor` → `NSColor`. `off` → this surface's
    /// `pal.primary`; `rainbowHue` rebuilds `NSColor(hue:…)` in the calibrated
    /// space exactly as before; `rgb` is sRGB (matching PaletteKit's hex init).
    private func nsColor(_ c: BorderColor) -> NSColor {
        switch c {
        case .off:
            return pal.primary
        case .rgb(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r), green: CGFloat(g),
                           blue: CGFloat(b), alpha: 1)
        case .rainbowHue(let h):
            return NSColor(hue: CGFloat(h), saturation: 0.9,
                           brightness: 1, alpha: 1)
        }
    }

    /// Current border color: the flash blink, the rotating rainbow hue, the
    /// cycling blend, the effect's steady color, or `pal.primary` when off.
    public var color: NSColor { nsColor(frame().color) }

    /// Current line width: breathing min↔max (raised cosine) or the fixed
    /// width, +1.5 pop during a flash.
    public var width: CGFloat { CGFloat(frame().width) }

    /// Start a WS-switch flash: a 5-blink burst through the effect's palette
    /// (random, no consecutive repeat), then settle. No-op off.
    public func flash() {
        guard let fx, !fx.flash.isEmpty else { return }
        flashState = rollFlash(fx.flash, now: now)
        updateTimer()
        onRepaint?()
    }

    /// Stop the animation timer. Call when the owning view is torn down (the
    /// transient grid / rail overlays) so no orphaned timer ticks.
    public func stop() { stopTimer() }

    /// Paint the current style onto a CALayer (tree / grid). The glow is a
    /// layer shadow in the current color; whether it blooms inward or outward
    /// depends on the parent layer's `masksToBounds`.
    public func apply(to layer: CALayer) {
        let fr = frame()
        let w = CGFloat(fr.width)
        let col = nsColor(fr.color)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.borderWidth = w
        layer.borderColor = col.cgColor
        if glowOn {
            layer.shadowColor = col.cgColor
            layer.shadowRadius = fr.flashing ? max(5, w * 5) : max(3, w * 3)
            layer.shadowOpacity = fr.flashing ? 0.95 : 0.85
            layer.shadowOffset = .zero
        } else {
            layer.shadowOpacity = 0
        }
        CATransaction.commit()
    }

    // MARK: - Timer

    /// Width breathes when both bounds are set with max > min.
    private var breathing: Bool {
        guard fx != nil, let lo = minW, let hi = maxW else { return false }
        return hi > lo
    }
    /// Anything to animate right now? (rainbow / cycle-colors / breathing, or
    /// a flash burst mid-flight). Drives the demand-gated timer.
    private var animating: Bool {
        let cyclingOrBreathing = (fx?.cycles ?? false) || (cycleColors && fx != nil) || breathing
        if fx != nil && cyclingOrBreathing { return true }
        return flashState?.isActive(now: now) ?? false
    }

    private func updateTimer() {
        if animating { startTimer() } else { stopTimer() }
    }

    private func startTimer() {
        guard timer == nil else { return }
        // 30 Hz, .common mode so it keeps ticking during interaction —
        // mirrors RailView's slide loop. Ignore the timer arg (capturing it
        // in a @MainActor closure trips Swift 6 sendability); stop via the
        // stored ref.
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func tick() {
        onRepaint?()
        // Nothing left to animate (cycle settled, flash burst done) → stop
        // until the next flash / config.
        if !animating { stopTimer() }
    }
}
