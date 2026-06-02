// Read-only **mac desktop** queries via private SkyLight.
//
// A "mac desktop" is one macOS native Space (what Mission Control
// labels "Desktop 1", "Desktop 2", …) — distinct from a *facet
// workspace* (facet's own virtual grouping). See docs/glossary.md.
//
// facet scopes its workspaces per mac desktop: each mac desktop keeps
// its own independent set of facet workspaces. To do that the adapter
// needs to know which mac desktop is currently active. That single
// fact is read here.
//
// READ-only + SIP-on. Verified working 2026-05-28 across live
// mac-desktop switches (memory: facet-per-native-space-ws). facet
// never MOVES a window across mac desktops — that path (the rejected
// hide "手法4") is a no-op on macOS 15+ and needs SIP-off; staying
// read-only keeps facet inside the public-API/"釈迦の掌" contract
// (facet-buddha-palm-principle).
//
// Apple's SkyLight (SLS) symbols below mirror the OS API verbatim
// (`SLSGetActiveSpace`, `SLSCopySpacesForWindows`, …) — those names
// stay as Apple ships them; only facet's own surface speaks "mac
// desktop". Symbols are dlsym-bound (like `_AXUIElementGetWindow` in
// AXFocus.swift) so we never link a private symbol at build time. If
// a symbol moves / goes away, `activeID()` returns 0 and the adapter
// falls back to a single shared catalog (= pre-feature behaviour).

import AppKit
import Darwin

// Resolved once at first use; immutable thereafter, so reads from
// any thread are safe (same pattern as `axGetWindow` in AXFocus).
nonisolated(unsafe) private let skylight: UnsafeMutableRawPointer? = dlopen(
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
    RTLD_NOW)

private func slSym(_ name: String) -> UnsafeMutableRawPointer? {
    if let h = skylight, let s = dlsym(h, name) { return s }
    // RTLD_DEFAULT: SkyLight is usually already resident via AppKit.
    return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
}

private typealias ConnFn = @convention(c) () -> Int32
private typealias ActiveSpaceFn = @convention(c) (Int32) -> UInt64
private typealias CopySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
private typealias CopySpacesForWindowsFn =
    @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
private typealias GetWindowLevelFn =
    @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> Int32

private let mainConnectionID: Int32? = {
    guard let s = slSym("SLSMainConnectionID") else { return nil }
    return unsafeBitCast(s, to: ConnFn.self)()
}()

private let getActiveSpaceFn: ActiveSpaceFn? = {
    guard let s = slSym("SLSGetActiveSpace") else { return nil }
    return unsafeBitCast(s, to: ActiveSpaceFn.self)
}()

private let copyManagedSpacesFn: CopySpacesFn? = {
    guard let s = slSym("SLSCopyManagedDisplaySpaces") else { return nil }
    return unsafeBitCast(s, to: CopySpacesFn.self)
}()

private let copySpacesForWindowsFn: CopySpacesForWindowsFn? = {
    guard let s = slSym("SLSCopySpacesForWindows") else { return nil }
    return unsafeBitCast(s, to: CopySpacesForWindowsFn.self)
}()

/// `0x7` = "all space types" selector (current + others + fullscreen),
/// the same mask yabai uses to enumerate a window's mac desktops. A normal
/// window resides on exactly one mac desktop, so the returned array is
/// usually single-element; sticky / all-desktops windows return many.
private let kSpacesAllMask: Int32 = 0x7

private let getWindowLevelFn: GetWindowLevelFn? = {
    guard let s = slSym("SLSGetWindowLevel") else { return nil }
    return unsafeBitCast(s, to: GetWindowLevelFn.self)
}()

/// Read-only queries about the **mac desktop** (native macOS Space)
/// layer, via private SkyLight. The facet-facing names below speak
/// "mac desktop"; the SLS symbols they wrap keep Apple's wording.
public enum MacDesktops {
    /// Current active mac desktop id (SkyLight `id64`). `0` means the
    /// private symbols are unavailable — callers treat that as "one
    /// global desktop" and keep a single catalog, i.e. the
    /// pre-per-desktop behaviour.
    public static func activeID() -> UInt64 {
        guard let cid = mainConnectionID, let f = getActiveSpaceFn
        else { return 0 }
        return f(cid)
    }

    /// Whether the SkyLight active-desktop symbols resolved. Surfaced
    /// in the adapter's init debug line so a future OS change that
    /// removes them is visible in the log (facet then falls back to
    /// a single shared catalog).
    public static var available: Bool {
        mainConnectionID != nil && getActiveSpaceFn != nil
    }

    /// Mac desktop id64s that `windowID` (a CGWindowID) is resident
    /// on, read-only via SkyLight `SLSCopySpacesForWindows`. Returns
    /// an EMPTY array when the symbol is unavailable, the query fails,
    /// or the window genuinely reports no desktop — callers MUST treat
    /// empty as "unknown, don't act" so a transient SkyLight miss
    /// can't wrongly evict a real window. Per memory
    /// `sls-copy-spaces-behavior` a single-window query returns that
    /// window's own desktops (no union ambiguity), so the result is
    /// directly usable for "is this window on desktop X?".
    public static func ids(forWindow windowID: Int) -> [UInt64] {
        guard windowID > 0, let cid = mainConnectionID,
              let f = copySpacesForWindowsFn else { return [] }
        let list = [NSNumber(value: windowID)] as CFArray
        guard let arr = f(cid, kSpacesAllMask, list)?.takeRetainedValue()
                as? [NSNumber] else { return [] }
        return arr.map { $0.uint64Value }
    }

    /// The window-server level of `windowID` (a CGWindowID), read-only
    /// via SkyLight `SLSGetWindowLevel` — the same non-blocking signal
    /// yabai / rift use to tell ordinary windows (normal level) from
    /// pop-ups / tool-tips / menus (raised levels). `nil` when the
    /// symbol is unavailable or the query fails; callers treat `nil`
    /// as "unknown — don't exclude on level alone". Cheaper than an AX
    /// round-trip, so it runs as the first gate before any AX probe.
    public static func windowLevel(forWindow windowID: Int) -> Int? {
        guard windowID > 0, let cid = mainConnectionID,
              let f = getWindowLevelFn else { return nil }
        var level: Int32 = 0
        guard f(cid, UInt32(windowID), &level) == 0 else { return nil }
        return Int(level)
    }

    /// 1-based position of `activeID` among **user** mac desktops
    /// (`type == 0`, i.e. excluding fullscreen Spaces), in Mission
    /// Control order across displays. This is the ordinal the user
    /// thinks in ("Desktop 1 / Desktop 2") and what `[desktop.N]`
    /// config keys against. Takes the already-known active id (callers
    /// have just read it) to avoid a redundant `SLSGetActiveSpace`.
    /// `nil` when SkyLight is unavailable or `activeID` isn't in the
    /// managed list.
    public static func ordinal(for activeID: UInt64) -> Int? {
        guard activeID != 0, let cid = mainConnectionID,
              let copy = copyManagedSpacesFn,
              let displays = copy(cid)?.takeRetainedValue()
                as? [[String: Any]]
        else { return nil }
        let active = activeID
        var ordinal = 0
        for display in displays {
            // "Spaces" is Apple's SLS dict key (kept verbatim); each
            // element is one mac desktop on this display.
            let spaces = display["Spaces"] as? [[String: Any]] ?? []
            for sp in spaces {
                let type = (sp["type"] as? NSNumber)?.intValue ?? 0
                guard type == 0 else { continue }   // skip fullscreen
                ordinal += 1
                if let id = (sp["id64"] as? NSNumber)?.uint64Value,
                   id == active {
                    return ordinal
                }
            }
        }
        return nil
    }
}
