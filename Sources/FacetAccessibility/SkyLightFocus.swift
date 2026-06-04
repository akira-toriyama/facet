// SPIKE (spike/focus-skylight-frontsignal): window-server-fresh focus
// resolution for the ④ shake + ⑤ active-window border fast-path.
//
// The main-thread `AX.frontmostFocusedCGID()` path (NSWorkspace
// .frontmostApplication + AX) is fast median but its front-app signal
// occasionally lags >150ms, so the fast-path poll misses and drops to
// the slow reconcile ("たまに遅い"). JankyBorders avoids this by reading
// the front process from the window server, which commits promptly.
//
// This resolver does the same with READ-only private SkyLight (same
// tier facet already uses for MacDesktops): `_SLPSGetFrontProcess` →
// `SLSGetConnectionIDForPSN` → `SLSConnectionGetPID` gives the fresh
// front pid, then CGWindowList z-order (also window-server state) gives
// that pid's topmost on-screen window. No AX, no NSWorkspace. Any
// missing symbol → nil, and the caller falls back to the AX path.

import AppKit
import Darwin

nonisolated(unsafe) private let skylight: UnsafeMutableRawPointer? = dlopen(
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
    RTLD_NOW)

private func slSym(_ name: String) -> UnsafeMutableRawPointer? {
    if let h = skylight, let s = dlsym(h, name) { return s }
    return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
}

private typealias ConnFn = @convention(c) () -> Int32
private typealias FrontProcFn =
    @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
private typealias CIDForPSNFn =
    @convention(c) (Int32, UnsafeMutablePointer<ProcessSerialNumber>,
                    UnsafeMutablePointer<Int32>) -> Int32
private typealias ConnGetPIDFn =
    @convention(c) (Int32, UnsafeMutablePointer<pid_t>) -> Int32

private let mainConnectionID: Int32? = {
    guard let s = slSym("SLSMainConnectionID") else { return nil }
    return unsafeBitCast(s, to: ConnFn.self)()
}()
private let getFrontProcessFn: FrontProcFn? = slSym("_SLPSGetFrontProcess")
    .map { unsafeBitCast($0, to: FrontProcFn.self) }
private let getCIDForPSNFn: CIDForPSNFn? = slSym("SLSGetConnectionIDForPSN")
    .map { unsafeBitCast($0, to: CIDForPSNFn.self) }
private let connGetPIDFn: ConnGetPIDFn? = slSym("SLSConnectionGetPID")
    .map { unsafeBitCast($0, to: ConnGetPIDFn.self) }

public enum SkyLightFocus {

    /// True when all symbols resolved — lets the adapter log which path
    /// the spike is actually running.
    public static var available: Bool {
        mainConnectionID != nil && getFrontProcessFn != nil
            && getCIDForPSNFn != nil && connGetPIDFn != nil
    }

    /// The window server's current front process pid (commits promptly,
    /// unlike `NSWorkspace.frontmostApplication`). `nil` if unavailable.
    public static func frontPID() -> pid_t? {
        guard let mainCID = mainConnectionID, let getFront = getFrontProcessFn,
              let cidForPSN = getCIDForPSNFn, let connPID = connGetPIDFn
        else { return nil }
        var psn = ProcessSerialNumber()
        guard getFront(&psn) == 0 else { return nil }
        var targetCID: Int32 = 0
        guard cidForPSN(mainCID, &psn, &targetCID) == 0 else { return nil }
        var pid: pid_t = 0
        guard connPID(targetCID, &pid) == 0, pid > 0 else { return nil }
        return pid
    }

    /// Window-server-fresh focused window = the front process's topmost
    /// on-screen normal (layer 0) window, from CGWindowList z-order.
    public static func frontmostFocusedCGID() -> CGWindowID? {
        guard let pid = frontPID() else { return nil }
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for dict in raw {                       // front-to-back z-order
            guard let owner = dict[kCGWindowOwnerPID as String] as? Int,
                  owner == Int(pid),
                  (dict[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let cgID = dict[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            return cgID
        }
        return nil
    }
}
