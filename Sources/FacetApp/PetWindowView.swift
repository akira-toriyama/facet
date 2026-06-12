// PetWindowView — line-pets drawn ON the panel's outer border, in front.
//
// Same shape as halo's `RingView`: a transparent, click-through overlay
// window that is `pad` LARGER than the panel on every side, so the pets
// can sit centred ON the border line (and bloom outward past the panel
// edge) without being clipped. The tree panel itself can't host them —
// its `effect` view rounds + `masksToBounds`-clips at the edge, so a
// sprite centred on the border there is cut in half (reads as "behind
// the border"). This view lives in the overlay window above the panel.
//
// The shared sill drawing (also halo's ring + wand's cards); this view
// owns only the rect + the draw call. NON-flipped so sill's `drawLinePets`
// (top == maxY) works directly. The Controller drives the redraw cadence
// via its 30 Hz theme-FX timer; `PanelHost` keeps the window glued to the
// panel frame (`bounds.insetBy(pad)` == the panel's outer edge).

import AppKit
import QuartzCore   // CACurrentMediaTime — line-pet animation clock
import FacetView     // re-exports sill's Effects (drawLinePets / LinePet)

final class PetWindowView: NSView {

    /// Margin between the overlay edge and the panel border the pets walk,
    /// giving the full sprite room to straddle the line without clipping.
    private let pad: CGFloat

    private var pets: [LinePet] = []
    private var petScale: CGFloat = 0.9
    private var petLapSeconds: CGFloat = 8

    init(pad: CGFloat) {
        self.pad = pad
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    /// Non-flipped: sill's `drawLinePets` reads "top" as `maxY`.
    override var isFlipped: Bool { false }

    /// Pure decoration — every click falls through to whatever's below.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Install the line-pet config (from `[tree]` via the Controller).
    /// Names are validated here — the seam where `Effects` is in scope —
    /// so an unknown name is silently dropped (lenient, matching the
    /// config layer's clamp-don't-reject policy). Empty ⇒ pets off.
    func setPets(names: [String], scale: CGFloat, lapSeconds: CGFloat) {
        pets = names.compactMap { LinePet(rawValue: $0) }
        petScale = scale
        petLapSeconds = lapSeconds
        needsDisplay = true
    }

    /// Whether any pet is configured — the Controller gates its redraw
    /// timer on this (pets need a steady repaint even on a static theme).
    var hasPets: Bool { !pets.isEmpty }

    override func draw(_ dirtyRect: NSRect) {
        guard !pets.isEmpty else { return }
        // The panel's outer border sits `pad` inside the overlay bounds.
        let rect = bounds.insetBy(dx: pad, dy: pad)
        guard rect.width > 0, rect.height > 0 else { return }
        // pt/s derived from the desired lap time so the orbit feels
        // equally lively regardless of panel size.
        let speed = 2 * (rect.width + rect.height) / petLapSeconds
        drawLinePets(pets, on: rect, now: CACurrentMediaTime(),
                     scale: petScale, speed: speed)
    }
}
