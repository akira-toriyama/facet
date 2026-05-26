// AX geometry primitives — get / set window position + size, look
// up an AX window element by CGWindowID, and resolve which display
// a point sits on. Shared by FacetAdapterNative's hide / move
// paths and any future consumer (Phase γ tiling, etc.).
//
// Lives next to AXFocus / AXTitles in FacetAccessibility so all
// AX-touching code stays in one module. Lifted out of
// FacetAdapterNative when it duplicated everything AXFocus.swift
// already had.

import AppKit
import ApplicationServices
import CoreGraphics
import FacetCore

public enum AXGeom {

    /// AX window element matching `cgID` inside the app `pid`'s
    /// AX window list. Walks the app's children once and
    /// returns the first match by `_AXUIElementGetWindow`. `nil`
    /// when the app refuses AX or the window has gone.
    public static func window(for cgID: CGWindowID, pid: pid_t)
        -> AXUIElement?
    {
        let app = AXUIElementCreateApplication(pid)
        var winsRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                app, kAXWindowsAttribute as CFString, &winsRef
            ) == .success,
            let wins = winsRef as? [AXUIElement]
        else { return nil }
        return wins.first { cgWindowID(of: $0) == cgID }
    }

    public static func position(_ win: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                win, kAXPositionAttribute as CFString, &ref
              ) == .success else { return nil }
        var pt = CGPoint.zero
        AXValueGetValue(ref as! AXValue, .cgPoint, &pt)
        return pt
    }

    @discardableResult
    public static func setPosition(_ win: AXUIElement, _ pt: CGPoint)
        -> Bool
    {
        var p = pt
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(
            win, kAXPositionAttribute as CFString, v) == .success
    }

    public static func size(_ win: AXUIElement) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                win, kAXSizeAttribute as CFString, &ref
              ) == .success else { return nil }
        var sz = CGSize.zero
        AXValueGetValue(ref as! AXValue, .cgSize, &sz)
        return sz
    }

    /// CGWindowID for an AX window element via the private
    /// `_AXUIElementGetWindow` (dlsym-bound in AXFocus.swift —
    /// the symbol is module-internal, so the wrapper lives here
    /// as the public surface).
    public static func cgWindowID(of ax: AXUIElement) -> CGWindowID? {
        guard let fn = axGetWindow else { return nil }
        var wid: CGWindowID = 0
        return fn(ax, &wid) == .success ? wid : nil
    }
}

public enum Displays {

    /// Pick the display whose bounds contain `point`. Falls back
    /// to the nearest display by centre distance, then the main
    /// display as a last resort. Quartz coords (top-left origin)
    /// — matches AX position / size, NOT NSScreen.frame (which
    /// is bottom-left).
    public static func containing(_ point: CGPoint) -> CGRect {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let screens = ids.map { CGDisplayBounds($0) }
        if let hit = screens.first(where: { $0.contains(point) }) {
            return hit
        }
        return screens.min(by: {
            hypot($0.midX - point.x, $0.midY - point.y) <
            hypot($1.midX - point.x, $1.midY - point.y)
        }) ?? CGDisplayBounds(CGMainDisplayID())
    }
}
