// AX-based "precise focus": activate an app *and* raise the specific
// window the user clicked. Plain `NSRunningApplication.activate`
// only brings the app frontmost — for multi-window apps it picks
// the last-focused window, which is the wrong one half the time.
//
// MOVE-AT-M5: this is not actually rift-specific. The native
// adapter (Phase α+) will need the same primitive. When
// FacetAdapterNative lands, extract this file and AXTitles to a
// shared FacetAccessibility module. Keeping it in
// FacetAdapterRift for M2 to avoid spinning up an empty module
// before there's a second consumer.

import AppKit
import ApplicationServices
import Darwin
import FacetCore

// Private API: `_AXUIElementGetWindow` translates an `AXUIElement`
// to its CGWindowID. Looked up via `dlsym` so we don't link against
// a private symbol at build time. `nil` means the symbol moved /
// went away — focus falls back to "activate app and hope for the
// best."
typealias AXGetWindowFn =
    @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError

let axGetWindow: AXGetWindowFn? = {
    guard let s = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                        "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(s, to: AXGetWindowFn.self)
}()

public enum AX {

    /// Focus `window` precisely: bring its owning app frontmost,
    /// then raise the specific window the user picked. Returns
    /// `true` if AX could resolve and focus the window, `false`
    /// if it fell back to activate-only.
    ///
    /// Matches the window first by CGWindowID via the private
    /// `_AXUIElementGetWindow`, then by title as a backup. Empty
    /// titles skip the title match (would otherwise focus any
    /// untitled window).
    @discardableResult
    public static func focus(_ window: Window) -> Bool {
        let app = AXUIElementCreateApplication(pid_t(window.pid))
        // Bound every AX round-trip so a busy app (e.g. Chrome) can't
        // stall us. 0.25 s is generous; the typical reply is <10 ms.
        AXUIElementSetMessagingTimeout(app, 0.25)
        var wr: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                app, kAXWindowsAttribute as CFString, &wr) == .success,
            let wins = wr as? [AXUIElement]
        else {
            Log.line("focus pid=\(window.pid) wsid=\(window.id.serverID): "
                + "no AX windows -> activate only")
            activate(pid: window.pid)
            return false
        }
        var target: AXUIElement?
        var matchBy = "none"
        let symOK = axGetWindow != nil
        if let g = axGetWindow {
            for w in wins {
                var cg: UInt32 = 0
                if g(w, &cg) == .success, Int(cg) == window.id.serverID {
                    target = w
                    matchBy = "wsid"
                    break
                }
            }
        }
        if target == nil, !window.title.isEmpty {
            for w in wins {
                var t: CFTypeRef?
                AXUIElementCopyAttributeValue(
                    w, kAXTitleAttribute as CFString, &t)
                if (t as? String) == window.title {
                    target = w
                    matchBy = "title"
                    break
                }
            }
        }
        Log.line(
            "focus pid=\(window.pid) wsid=\(window.id.serverID) "
            + "title=\"\(window.title)\" symOK=\(symOK) "
            + "wins=\(wins.count) match=\(matchBy)")
        guard let w = target else {
            activate(pid: window.pid)
            return false
        }
        // Order matters for multi-window apps: bring the app
        // frontmost first via AX, then make THIS window main, then
        // raise it last so it ends on top.
        AXUIElementSetAttributeValue(
            app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(
            w, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(
            w, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        return true
    }

    /// Prompt the user to grant Accessibility if not already trusted.
    /// Idempotent — system shows the alert once and remembers.
    public static func ensureTrusted() {
        if !AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
            FileHandle.standardError.write(Data(
                "facet: grant Accessibility, then relaunch.\n".utf8))
        }
    }

    private static func activate(pid: Int) {
        Task { @MainActor in
            NSRunningApplication(processIdentifier: pid_t(pid))?
                .activate(options: [.activateIgnoringOtherApps])
        }
    }
}
