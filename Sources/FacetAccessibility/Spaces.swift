// Read-only native macOS Space queries via private SkyLight.
//
// facet scopes its virtual workspaces per native macOS Space: each
// Space keeps its own independent set of facet workspaces. To do
// that the adapter needs to know which native Space is currently
// active. That single fact is read here.
//
// READ-only + SIP-on. Verified working 2026-05-28 across live Space
// switches (memory: facet-per-native-space-ws). facet never MOVES a
// window across Spaces — that path (the rejected hide "手法4") is a
// no-op on macOS 15+ and needs SIP-off; staying read-only keeps
// facet inside the public-API/"釈迦の掌" contract
// (facet-buddha-palm-principle).
//
// Symbols are dlsym-bound (like `_AXUIElementGetWindow` in
// AXFocus.swift) so we never link a private symbol at build time.
// If a symbol moves / goes away, `activeSpaceID()` returns 0 and
// the adapter falls back to a single shared catalog (= pre-feature
// behaviour).

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

public enum Spaces {
    /// Current active native macOS Space id (SkyLight `id64`).
    /// `0` means the private symbols are unavailable — callers
    /// treat that as "one global space" and keep a single catalog,
    /// i.e. the pre-per-Space behaviour.
    public static func activeSpaceID() -> UInt64 {
        guard let cid = mainConnectionID, let f = getActiveSpaceFn
        else { return 0 }
        return f(cid)
    }

    /// Whether the SkyLight active-space read resolved at all. Lets
    /// the adapter log a one-time hint when the symbols are gone.
    public static var available: Bool {
        mainConnectionID != nil && getActiveSpaceFn != nil
    }

    /// 1-based position of the active Space among **user** Spaces
    /// (`type == 0`, i.e. excluding fullscreen Spaces), in Mission
    /// Control order across displays. This is the ordinal the user
    /// thinks in ("native WS1 / WS2") and what `[space.N]` config
    /// keys against. `nil` when SkyLight is unavailable or the
    /// active Space can't be located in the managed list.
    public static func activeSpaceOrdinal() -> Int? {
        guard let cid = mainConnectionID, let copy = copyManagedSpacesFn
        else { return nil }
        let active = activeSpaceID()
        guard active != 0,
              let displays = copy(cid)?.takeRetainedValue()
                as? [[String: Any]]
        else { return nil }
        var ordinal = 0
        for display in displays {
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
