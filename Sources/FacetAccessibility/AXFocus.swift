// AX-based "precise focus": activate an app *and* raise the specific
// window the user clicked. Plain `NSRunningApplication.activate`
// only brings the app frontmost — for multi-window apps it picks
// the last-focused window, which is the wrong one half the time.
//
// Lives in FacetAccessibility (lifted out of FacetAdapterRift at
// M5 when the native adapter became the second consumer).
// FacetAdapterNative is the only adapter consumer since v2.0.0
// retired rift; the FacetApp Controller / Main also call
// `AX.focus` / `AX.ensureTrusted` directly.

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
        // Precise focus, public API only: mark the target main, raise
        // it, then hand activation to the owning app. Works for same-app
        // / same-WS focus because facet's tree panel never grabs key on a
        // click (KeyablePanel.canBecomeKey is gated to explicit kb-nav
        // entry) — if it held key, no public call could re-key another
        // app's window; that was the same-app focus bug. AeroSpace works
        // the same way and has no key-grabbing panel.
        //
        // Cross-app focus uses `activateFront` (cooperative
        // `activate(from:)`, macOS 14+) instead of the deprecated
        // `.activateIgnoringOtherApps`, which macOS 15 ignores for a
        // background app — that was the "tree click on another app's
        // window doesn't focus it" bug. facet stays non-active throughout.
        //
        // KNOWN LIMITATION (deferred): after a workspace switch the
        // keyboard focus can stay "pending" until the next real HID
        // event — the user nudging the mouse commits it. Synthetic
        // mouse-moves don't commit (only a click does), so cross-WS focus
        // may need a tiny mouse move to start typing. Revisit separately.
        AXUIElementSetAttributeValue(
            w, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        // Cross-app hand-off (cooperative activation; see activateFront).
        // Off-main here, so hop to the main actor for NSApp / NSWorkspace.
        Task { @MainActor in activateFront(pid: window.pid) }
        Log.debug("focus applied main+raise+activate "
            + "pid=\(window.pid) wsid=\(window.id.serverID)")
        return true
    }

    /// Bring a window to the front of its app's z-order *without*
    /// taking keyboard focus or activating the owning app —
    /// `kAXRaiseAction` only. Used to surface a freshly-opened
    /// floating window (sheet / dialog / palette / `[[exclude]]`
    /// `action="float"`) on first sight so it isn't born buried,
    /// while keeping facet's never-steal-focus contract. Contrast
    /// `focus(_:)`, which also sets `kAXMain` *and* activates the app
    /// (steals focus). This is the "raise" half of `[window]
    /// raise-on-open`; the "activate" escalation is `activateApp`.
    public static func raise(_ ax: AXUIElement) {
        // Bound the round-trip like `focus` so a busy app can't stall
        // the classify pass (which feeds the per-cycle probe budget).
        AXUIElementSetMessagingTimeout(ax, 0.25)
        AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
    }

    /// Bring an app frontmost (this *does* steal focus). Backs
    /// `[window] raise-on-open = "activate"`, which fronts the owning
    /// app for every fresh float (chosen when a bare `raise` —
    /// `kAXRaiseAction`, z-order within the owning app only — can't
    /// surface a float that opens under a *different* app). Fired once
    /// per fresh float, not a continuous pin.
    public static func activateApp(pid: Int) {
        activate(pid: pid)
    }

    /// CGWindowID of the currently focused window across the
    /// system, resolved via NSWorkspace's frontmost app + that
    /// app's `kAXFocusedWindowAttribute`. `nil` when:
    ///   - no frontmost app (rare; transient between apps)
    ///   - app refuses AX (sandboxed / non-cooperative)
    ///   - AX has no focused window for this app right now
    ///   - `_AXUIElementGetWindow` (looked up via dlsym in
    ///     `AXGeom.cgWindowID`) returns failure
    ///
    /// Both adapters need this seam — `NativeAdapter.focusedWindow`
    /// to stamp `Window.isFocused` in its snapshot, and any future
    /// adapter that wants the same answer without re-implementing
    /// the dance.
    public static func frontmostFocusedCGID() -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication
        else { return nil }
        let axApp = AXUIElementCreateApplication(
            pid_t(app.processIdentifier))
        // Bound the per-app AX round-trip like every other hot-path
        // read (AX.focus / AX.raise / AXTitles.resolve) so a hung
        // frontmost app can't stall this — `focusedWindow()` re-reads
        // it up to 50× per assertBlocking sequence on cliQueue.
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                axApp, kAXFocusedWindowAttribute as CFString,
                &winRef) == .success,
              let raw = winRef
        else { return nil }
        // `kAXFocusedWindowAttribute` always returns an
        // AXUIElement; the cast is unconditional (Swift warns on
        // `as?`). force-cast here matches the AX type contract.
        let element = raw as! AXUIElement
        return AXGeom.cgWindowID(of: element)
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
        Task { @MainActor in activateFront(pid: pid) }
    }

    /// Bring another app frontmost from accessory facet — the cross-app
    /// half of a tree click. macOS 14 (Sonoma) deprecated
    /// `.activateIgnoringOtherApps` for a *cooperative* model: a
    /// background (non-active) app can no longer force another app
    /// frontmost, so facet's old
    /// `NSRunningApplication.activate(options:.activateIgnoringOtherApps)`
    /// became a silent no-op on macOS 15 and a tree click on a
    /// *different* app's window stopped focusing it. (Same-app still
    /// works — it needs no activation, just `kAXMain`+`kAXRaise`.)
    ///
    /// `NSRunningApplication.activate(from:)` (macOS 14+) is the
    /// cooperative replacement: it transfers activation from the current
    /// front app to the target. Verified to work while facet itself
    /// stays NON-active — facet never becomes the active app, so the
    /// never-steal-focus / nonactivating contract holds and there's no
    /// Dock-icon flicker. Public API only; no private SkyLight write.
    ///
    /// Idempotent: the `Focus` retry loops call this repeatedly per
    /// focus; once the target is frontmost the `!isActive` guard makes
    /// every later call a no-op. Main-actor (`NSApp` / `NSWorkspace`).
    @MainActor
    static func activateFront(pid: Int) {
        guard let target = NSRunningApplication(
                processIdentifier: pid_t(pid)),
              !target.isActive else { return }
        if #available(macOS 14.0, *) {
            if let from = NSWorkspace.shared.frontmostApplication,
               from.processIdentifier != target.processIdentifier,
               target.activate(from: from) {
                return
            }
            target.activate()       // no front app / refused hand-off
        } else {
            target.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
