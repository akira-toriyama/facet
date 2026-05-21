// Side-by-side NSPanel resize sandbox.
//
// Usage:
//   swift run panel-sandbox
//
// Opens 8 plain panels (no chevron, no custom grip — just AppKit /
// NSPanel knobs) in a 4×2 grid so OS-level resize behaviour can be
// A/B-tested. Each panel shows its config so verification is direct.
//
// Quit: cmd+Q.

import AppKit

@main
enum PanelSandbox {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

/// Each variant captures the styleMask + extra knobs we want to
/// compare. Adding a new variant: append a `Variant` to `all` —
/// no other code change.
struct Variant {
    let id: String
    let label: String          // shown in the panel body
    let styleMask: NSWindow.StyleMask
    let hasShadow: Bool
    let lockSize: Bool         // sets min == max == initial frame
    let title: String?         // only meaningful for titled panels
    let acceptsMouseMoved: Bool

    static let all: [Variant] = [
        Variant(id: "A",
                label: "A\nborderless\nnonactivating\n(baseline)",
                styleMask: [.borderless, .nonactivatingPanel],
                hasShadow: true,
                lockSize: false,
                title: nil,
                acceptsMouseMoved: false),
        Variant(id: "B",
                label: "B\nA + .resizable",
                styleMask: [.borderless, .nonactivatingPanel, .resizable],
                hasShadow: true,
                lockSize: false,
                title: nil,
                acceptsMouseMoved: false),
        Variant(id: "C",
                label: "C\nB + hasShadow=false",
                styleMask: [.borderless, .nonactivatingPanel, .resizable],
                hasShadow: false,
                lockSize: false,
                title: nil,
                acceptsMouseMoved: false),
        Variant(id: "D",
                label: "D\n.titled +\n.nonactivating +\n.resizable",
                styleMask: [.titled, .nonactivatingPanel, .resizable],
                hasShadow: true,
                lockSize: false,
                title: "Panel D",
                acceptsMouseMoved: false),
        Variant(id: "E",
                label: "E\nborderless\n(no nonactivating)\n+ .resizable",
                styleMask: [.borderless, .resizable],
                hasShadow: true,
                lockSize: false,
                title: nil,
                acceptsMouseMoved: false),
        Variant(id: "F",
                label: "F\nA + min==max\n(facet lock)",
                styleMask: [.borderless, .nonactivatingPanel],
                hasShadow: true,
                lockSize: true,
                title: nil,
                acceptsMouseMoved: false),
        Variant(id: "G",
                label: "G\nB +\nacceptsMouseMovedEvents",
                styleMask: [.borderless, .nonactivatingPanel, .resizable],
                hasShadow: true,
                lockSize: false,
                title: nil,
                acceptsMouseMoved: true),
        Variant(id: "H",
                label: "H\n.titled + .resizable\n+ .closable\n(full chrome)",
                styleMask: [.titled, .resizable, .closable],
                hasShadow: true,
                lockSize: false,
                title: "Panel H",
                acceptsMouseMoved: false),
    ]
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panels: [NSPanel] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        guard let screen = NSScreen.main else { return }
        let scr = screen.visibleFrame

        let cols = 4
        let rows = 2
        let panelW: CGFloat = 240
        let panelH: CGFloat = 220
        let gap: CGFloat = 24
        let gridW = panelW * CGFloat(cols) + gap * CGFloat(cols - 1)
        let gridH = panelH * CGFloat(rows) + gap * CGFloat(rows - 1)
        let originX = scr.minX + (scr.width - gridW) / 2
        let originY = scr.minY + (scr.height - gridH) / 2

        for (i, v) in Variant.all.enumerated() {
            let col = i % cols
            let row = i / cols
            // row 0 is top; AppKit screen coord is bottom-left.
            let x = originX + CGFloat(col) * (panelW + gap)
            let y = originY + CGFloat(rows - 1 - row) * (panelH + gap)
            panels.append(makePanel(variant: v,
                                    origin: NSPoint(x: x, y: y),
                                    size: NSSize(width: panelW, height: panelH)))
        }
    }

    private func makePanel(variant v: Variant,
                           origin: NSPoint,
                           size: NSSize) -> NSPanel {
        let rect = NSRect(origin: origin, size: size)
        let panel = KeyablePanel(contentRect: rect,
                                 styleMask: v.styleMask,
                                 backing: .buffered,
                                 defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = v.hasShadow
        panel.hidesOnDeactivate = false
        if let t = v.title { panel.title = t }
        if v.acceptsMouseMoved { panel.acceptsMouseMovedEvents = true }

        // Borderless panels need a custom background; titled ones
        // use the system chrome (leave their bg as default).
        let isTitled = v.styleMask.contains(.titled)
        if !isTitled {
            panel.backgroundColor = .clear
            panel.isOpaque = false
        }

        let host = NSView(frame: rect)
        host.wantsLayer = true
        host.layer?.backgroundColor = colorFor(v.id).cgColor
        if !isTitled { host.layer?.cornerRadius = 10 }
        host.layer?.borderWidth = 1
        host.layer?.borderColor = NSColor.white
            .withAlphaComponent(0.35).cgColor

        let label = NSTextField(labelWithString: v.label)
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor,
                                         constant: -16),
        ])

        panel.contentView = host
        panel.orderFrontRegardless()

        if v.lockSize {
            // Apply after orderFront so the initial frame is known
            // and locked to itself.
            panel.minSize = panel.frame.size
            panel.maxSize = panel.frame.size
        }
        return panel
    }

    /// Stable hue per variant id so the eye can pick A/B/C/... at
    /// a glance even when their labels look similar.
    private func colorFor(_ id: String) -> NSColor {
        let palette: [NSColor] = [
            .systemRed, .systemBlue, .systemGreen, .systemOrange,
            .systemPurple, .systemTeal, .systemPink, .systemBrown,
        ]
        let idx = Int(id.unicodeScalars.first!.value)
            - Int(("A" as Unicode.Scalar).value)
        let base = palette[(idx % palette.count + palette.count) % palette.count]
        return base.withAlphaComponent(0.30)
    }
}

/// Borderless NSPanel reports canBecomeKey == false by default; mirror
/// facet's KeyablePanel so the sandbox panels can actually become key
/// (a prerequisite for some of the resize behaviours we want to test).
@MainActor
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
