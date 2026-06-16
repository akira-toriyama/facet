// AX geometry primitives — get / set window position + size, look
// up an AX window element by CGWindowID, and resolve which display
// a point sits on. Shared by FacetAdapterNative's hide / move /
// tile / stack paths.
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
              ) == .success,
              let v = ref, CFGetTypeID(v) == AXValueGetTypeID()
        else { return nil }
        var pt = CGPoint.zero
        guard AXValueGetValue(v as! AXValue, .cgPoint, &pt) else { return nil }
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
              ) == .success,
              let v = ref, CFGetTypeID(v) == AXValueGetTypeID()
        else { return nil }
        var sz = CGSize.zero
        guard AXValueGetValue(v as! AXValue, .cgSize, &sz) else { return nil }
        return sz
    }

    @discardableResult
    public static func setSize(_ win: AXUIElement, _ size: CGSize)
        -> Bool
    {
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(
            win, kAXSizeAttribute as CFString, v) == .success
    }

    /// Whether AX will let us move the window — `kAXPositionAttribute`
    /// is settable. yabai / rift gate on this (`window_can_move`): a
    /// window we can't reposition can't be tiled (we'd hand it a slot
    /// it can't fill), so an immovable standard window is floated
    /// rather than tiled. Read-only probe; pairs with the subrole +
    /// window-level gate.
    public static func canMove(_ win: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(
            win, kAXPositionAttribute as CFString, &settable
        ) == .success && settable.boolValue
    }

    /// AX `kAXRoleAttribute` of a window element, or nil when
    /// the attribute is missing / the app refuses AX. Used by
    /// the native adapter to auto-detect floating windows
    /// (sheets, dialogs, palettes) on first sight.
    public static func role(_ win: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                win, kAXRoleAttribute as CFString, &ref
              ) == .success else { return nil }
        return ref as? String
    }

    /// AX `kAXSubroleAttribute` of a window element, or nil
    /// when missing. macOS uses subroles to mark floating
    /// panels (`kAXFloatingWindowSubrole`, `kAXSystemDialogSubrole`).
    public static func subrole(_ win: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                win, kAXSubroleAttribute as CFString, &ref
              ) == .success else { return nil }
        return ref as? String
    }

    /// True when the window's AX role / subrole identifies it
    /// as a transient / floating-style window (system dialog,
    /// sheet, floating palette). The native adapter consumes
    /// this as a first-sight hint for its auto-float
    /// (`facet-phase-gamma-decisions` Q4): once a window is
    /// known to the catalog, the user's manual `toggleFloat`
    /// is authoritative — we do NOT re-promote on every refresh.
    /// Conservative: only the well-known role / subrole values
    /// are treated as floating — unknown roles fall through to
    /// regular tiling.
    public static func isFloatingByRole(_ win: AXUIElement) -> Bool {
        isFloating(role: role(win), subrole: subrole(win))
    }

    /// Pure role / subrole → floating decision — the testable core of
    /// `isFloatingByRole`, split out so the rule can be unit-tested
    /// without a live `AXUIElement`. Sheet / drawer are *roles*;
    /// SystemDialog / SystemFloatingWindow / FloatingWindow / Dialog
    /// are *sub*roles (`AXSystemDialog` etc.), not top-level roles.
    /// Conservative: anything else — including `nil` — is not floating.
    public static func isFloating(role: String?, subrole: String?) -> Bool {
        if let r = role,
           r == kAXSheetRole as String
           || r == kAXDrawerRole as String {
            return true
        }
        if let sub = subrole,
           sub == kAXFloatingWindowSubrole as String
           || sub == kAXSystemDialogSubrole as String
           || sub == kAXSystemFloatingWindowSubrole as String
           || sub == kAXDialogSubrole as String {
            return true
        }
        return false
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

    /// Press the window's close button via AX. Equivalent to
    /// clicking the red traffic-light close button — apps may
    /// intercept with a "save changes?" dialog, so success here
    /// means "press dispatched", not "window gone".
    /// Returns false when the window has no close button (rare —
    /// utility windows, sheets in some modes) or AX rejected.
    @discardableResult
    public static func closeButton(_ win: AXUIElement) -> Bool {
        var btnRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                win, kAXCloseButtonAttribute as CFString, &btnRef
              ) == .success,
              let raw = btnRef else { return false }
        let btn = raw as! AXUIElement
        return AXUIElementPerformAction(
            btn, kAXPressAction as CFString) == .success
    }

    /// Set (or clear) the window's miniaturized state. `false`
    /// un-minimizes a Cmd+M'd window — used by hide-reclaim's
    /// click-to-restore. Returns false when AX rejected.
    @discardableResult
    public static func setMinimized(_ win: AXUIElement, _ on: Bool) -> Bool {
        AXUIElementSetAttributeValue(
            win, kAXMinimizedAttribute as CFString,
            on as CFBoolean) == .success
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

    /// Bottom-right 1px anchor-sliver point on the display containing
    /// `point` — the on-screen park position that dodges macOS's
    /// off-screen clamp (memory: [[native-window-hide-methods]] 手法4).
    /// `(maxX-1, maxY-1)` stays a pixel inside the bounds so the window
    /// keeps `isOnscreen == true` while parked.
    public static func anchorSliver(near point: CGPoint) -> CGPoint {
        let s = containing(point)
        return CGPoint(x: s.maxX - 1, y: s.maxY - 1)
    }

    /// Visible rect (display bounds minus menu bar / Dock) for
    /// the display containing `point`, in **Quartz coords**
    /// (top-left origin), to match what AX `kAXPositionAttribute`
    /// expects. Looks up the matching `NSScreen` and converts
    /// `visibleFrame` (which is in NSScreen coords / bottom-left)
    /// using the primary screen's height as the conversion
    /// reference. Falls back to `containing(point)` (full
    /// bounds) when no NSScreen match — better to tile into the
    /// full display than to no-op.
    /// The `NSScreen` whose frame contains `point`, falling back to the
    /// main screen. Shared by `visibleFrame` / `backingScaleFactor`.
    @MainActor
    private static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    @MainActor
    public static func visibleFrame(containing point: CGPoint)
        -> CGRect
    {
        guard let s = screen(containing: point),
              let primary = NSScreen.screens.first else {
            return containing(point)
        }
        let v = s.visibleFrame
        // Convert NS bottom-left → Quartz top-left, against the
        // primary display's height (the reference frame for the
        // global NS coordinate system).
        let primaryHeight = primary.frame.height
        return CGRect(
            x: v.origin.x,
            y: primaryHeight - v.origin.y - v.height,
            width: v.width,
            height: v.height)
    }

    /// `backingScaleFactor` of the display containing `point` (same
    /// NSScreen lookup as `visibleFrame`): 1.0 non-Retina, 2.0
    /// Retina, 3.0 on some. Falls back to the main screen, then 2.0
    /// (the common Retina case). Used to round tile frames to whole
    /// physical pixels so HiDPI window edges stay crisp.
    @MainActor
    public static func backingScaleFactor(containing point: CGPoint)
        -> CGFloat
    {
        screen(containing: point)?.backingScaleFactor ?? 2.0
    }
}
