// Borderless, click-through overlay panel that shows a captured
// window image as a popover next to the sidebar row that triggered
// it. Never key / never active — the facet panel stays fully
// operable on top of it. Used by the tree view (hover preview of
// off-screen windows) and the grid view (TBD).
//
// `level = .statusBar` puts the overlay above ordinary windows but
// the facet panel itself is raised above `.statusBar`, so the
// panel stays clickable.

import AppKit
import FacetCore

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

    /// `screenFrame` is the final on-screen panel rect in AppKit
    /// coords (bottom-left origin). Caller is responsible for
    /// sizing + positioning — see `Controller.popoverFrame`.
    public func show(_ img: NSImage, at screenFrame: NSRect, for id: WindowID) {
        shownWindow = id
        iv.image = img
        iv.layer?.borderColor = pal.accent.cgColor
        panel.setFrame(screenFrame, display: true)
        panel.orderFront(nil)                 // not makeKey: never steals focus
    }

    public func hide() {
        guard shownWindow != nil else { return }
        shownWindow = nil
        panel.orderOut(nil)
    }
}
