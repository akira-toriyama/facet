// Borderless, click-through overlay panel that shows a captured
// window image at that window's real on-screen position. Never key
// / never active — the facet panel stays fully operable on top of
// it. Used by the tree view (hover preview of off-screen windows)
// and the grid view (TBD).
//
// `level = .statusBar` puts the overlay above ordinary windows but
// the facet panel itself is raised above `.statusBar`, so the
// panel stays clickable.

import AppKit
import FacetCore

/// `SCWindow.frame` is in global display points, top-left origin
/// (Quartz). AppKit window frames are bottom-left, measured from
/// the primary screen. Convert for the primary display; multi-
/// display arrangements are not yet handled here.
@MainActor
public func cgFrameToAppKit(_ r: CGRect) -> NSRect {
    let primaryH = (NSScreen.screens.first { $0.frame.origin == .zero }?
        .frame.height) ?? NSScreen.main?.frame.height ?? r.maxY
    return NSRect(x: r.minX, y: primaryH - r.maxY,
                  width: r.width, height: r.height)
}

@MainActor
public final class PreviewOverlay {
    private let panel: NSPanel
    private let iv = NSImageView()
    public private(set) var shownWindow: WindowID?

    public init() {
        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true       // click-through
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .fullScreenAuxiliary]
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 8
        iv.layer?.cornerCurve = .continuous
        iv.layer?.masksToBounds = true
        iv.layer?.borderWidth = 2
        panel.contentView = iv
    }

    public func show(_ img: NSImage, at cgFrame: CGRect, for id: WindowID) {
        shownWindow = id
        iv.image = img
        iv.layer?.borderColor = pal.accent.cgColor
        panel.setFrame(cgFrameToAppKit(cgFrame), display: true)
        panel.orderFront(nil)                 // not makeKey: never steals focus
    }

    public func hide() {
        guard shownWindow != nil else { return }
        shownWindow = nil
        panel.orderOut(nil)
    }
}
