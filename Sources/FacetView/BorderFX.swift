// Shared neon-border animator. Holds the `[border]` config + the live
// animation state (rainbow hue cycle, width breath, WS-switch flash)
// and drives one 30 Hz timer; the owning view renders the current
// `color` / `width` / `glow` in whatever way suits it — a CALayer
// (tree panel, grid overlay) via `apply(to:)`, or a Core-Graphics
// stroke (rail strip) by reading the values in `draw(_:)`. The owner
// supplies `onRepaint` (set the layer, or `needsDisplay = true`).
//
// One instance per view. The border is independent of `theme`; an
// effect layers on top of any palette. See FacetConfig's `[border]`
// keys and sill's `Effects` module (`EffectSpec`) for the palettes.

import AppKit
import Effects
import PaletteKit

@MainActor
public final class BorderFX {

    // Config (from `[border]`).
    private var fx: EffectSpec?
    /// `fx` resolved to NSColors once at `configure` time — the shared
    /// `EffectSpec` is pure `UInt32` hex, but the render paths want
    /// `NSColor`s, so materialize the steady + flash colors here.
    private var steadyColor: NSColor = .clear
    private var flashColors: [NSColor] = []
    private var glowOn = false
    private var baseW: CGFloat = 1.5
    private var cycleSeconds: CGFloat = 6
    private var minW: CGFloat?
    private var maxW: CGFloat?
    /// Continuously loop a non-rainbow effect's color through its own
    /// flash palette (over `cycleSeconds`). On when `[border]
    /// cycle-seconds` is explicitly set; rainbow cycles regardless.
    private var cycleColors = false

    // Live animation state.
    private var cyclePhase: CGFloat = 0          // 0…1 hue / breath phase
    private var flashSeq: [NSColor] = []
    private var flashStep = -1                   // -1 = not flashing
    private var timer: Timer?

    /// Called on every tick + on configure / flash. The owner repaints:
    /// `apply(to: layer)` for a CALayer, or `needsDisplay = true` for a
    /// draw()-based view.
    public var onRepaint: (() -> Void)?

    public init() {}

    /// Push the `[border]` config. `effectName == "off"` (or unknown)
    /// leaves `active == false`.
    public func configure(effectName: String, glow: Bool, width: CGFloat,
                          cycleSeconds cs: CGFloat, cycleColors cc: Bool,
                          minWidth: CGFloat?, maxWidth: CGFloat?) {
        fx = borderEffectFor(effectName)
        steadyColor = fx.map { NSColor(hex: $0.steady) } ?? .clear
        flashColors = fx?.flash.map { NSColor(hex: $0) } ?? []
        glowOn = glow && fx != nil
        baseW = width
        cycleSeconds = max(1, cs)
        cycleColors = cc
        minW = minWidth
        maxW = maxWidth
        updateTimer()
        onRepaint?()
    }

    /// Whether an effect is active (vs "off"). Grid / rail draw a border
    /// only when active; the tree panel draws a plain accent border even
    /// when off (so `color` falls back to `pal.primary`).
    public var active: Bool { fx != nil }
    public var glowEnabled: Bool { glowOn }
    private var flashing: Bool { flashStep >= 0 && flashStep < flashSeq.count }

    /// Width breathes when both bounds are set with max > min.
    private var breathing: Bool {
        guard fx != nil, let lo = minW, let hi = maxW else { return false }
        return hi > lo
    }
    private var cyclingOrBreathing: Bool {
        (fx?.cycles ?? false) || (cycleColors && fx != nil) || breathing
    }

    /// Current border color: the flash blink, the rotating rainbow hue,
    /// the effect's fixed steady color, or `pal.primary` when off.
    public var color: NSColor {
        if flashing { return flashSeq[flashStep] }
        guard let fx else { return pal.primary }
        if fx.cycles {
            return NSColor(hue: cyclePhase, saturation: 0.9,
                           brightness: 1, alpha: 1)
        }
        if cycleColors, !flashColors.isEmpty {
            return blendThrough(flashColors, at: cyclePhase)
        }
        return steadyColor
    }

    /// Current line width: breathing min↔max (raised cosine) or the
    /// fixed width, +1.5 pop during a flash.
    public var width: CGFloat {
        var w = baseW
        if breathing, let lo = minW, let hi = maxW {
            let pulse = (1 - CGFloat(cos(2 * Double.pi * Double(cyclePhase)))) / 2
            w = lo + (hi - lo) * pulse
        }
        return flashing ? w + 1.5 : w
    }

    /// Start a WS-switch flash: a 5-blink burst through the effect's
    /// palette (random, no consecutive repeat), then settle. No-op off.
    public func flash() {
        guard fx != nil, !flashColors.isEmpty else { return }
        var idxs: [Int] = []
        var last = -1
        for _ in 0..<5 {
            var i = Int.random(in: 0..<flashColors.count)
            if flashColors.count > 1 { while i == last { i = Int.random(in: 0..<flashColors.count) } }
            idxs.append(i); last = i
        }
        flashSeq = idxs.map { flashColors[$0] }
        flashStep = 0
        updateTimer()
        onRepaint?()
    }

    /// Stop the animation timer. Call when the owning view is torn down
    /// (the transient grid / rail overlays) so no orphaned timer ticks.
    public func stop() { stopTimer() }

    /// Paint the current style onto a CALayer (tree / grid). The glow is
    /// a layer shadow in the current color; whether it blooms inward or
    /// outward depends on the parent layer's `masksToBounds`.
    public func apply(to layer: CALayer) {
        let w = width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.borderWidth = w
        layer.borderColor = color.cgColor
        if glowOn {
            layer.shadowColor = color.cgColor
            layer.shadowRadius = flashing ? max(5, w * 5) : max(3, w * 3)
            layer.shadowOpacity = flashing ? 0.95 : 0.85
            layer.shadowOffset = .zero
        } else {
            layer.shadowOpacity = 0
        }
        CATransaction.commit()
    }

    // MARK: - Timer

    private func updateTimer() {
        if (fx != nil && cyclingOrBreathing) || flashing { startTimer() }
        else { stopTimer() }
    }

    private func startTimer() {
        guard timer == nil else { return }
        // 30 Hz, .common mode so it keeps ticking during interaction —
        // mirrors RailView's slide loop. Ignore the timer arg (capturing
        // it in a @MainActor closure trips Swift 6 sendability); stop via
        // the stored ref.
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func tick() {
        if flashing {
            flashStep += 1
            if flashStep >= flashSeq.count { flashStep = -1 }   // settled
        }
        if fx != nil && cyclingOrBreathing {
            cyclePhase += (1.0 / 30.0) / cycleSeconds
            if cyclePhase >= 1 { cyclePhase -= 1 }
        }
        onRepaint?()
        // Nothing left to animate → stop until the next flash / config.
        if !flashing && !(fx != nil && cyclingOrBreathing) { stopTimer() }
    }
}
