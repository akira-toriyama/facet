// Native-adapter feasibility spike (M5 Phase α). Throwaway probe.
//
// Answers the go/no-go questions for FacetAdapterNative:
//   1. Can we enumerate windows with a public API (CGWindowList)?
//   2. Can we map CGWindowID <-> AXUIElement (identity)?
//   3. Can we move a window off-screen via AX and restore it
//      (the virtual-workspace hide/show mechanism)? And critically:
//      does the parked window actually "disappear" (Cmd-Tab /
//      Mission Control)?
//   4. Can we focus a window via AX (raise + activate)?
//   5. Can we read the active space + per-window spaces via CGS/SLS
//      (dlsym into SkyLight, no SIP disable)?
//
// Usage:
//   swift run native-spike list                 # enumerate + spaces
//   swift run native-spike park <cgWindowID>    # off-screen 5s, restore
//   swift run native-spike focus <cgWindowID>   # raise + activate
//
// All AX calls need Accessibility granted to the *terminal* running
// this (System Settings → Privacy & Security → Accessibility).

import AppKit
import ApplicationServices

// MARK: - SkyLight / CGS dlsym (private, but SIP-clean — read/query)

/// Lazily-resolved SkyLight handle + the few CGS/SLS functions the
/// spike needs. Force-unwraps: if the framework or a symbol is gone
/// we *want* a loud crash in a spike.
enum SkyLight {
    nonisolated(unsafe) static let handle: UnsafeMutableRawPointer = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_NOW)!

    typealias MainConnFn = @convention(c) () -> Int32
    typealias ActiveSpaceFn = @convention(c) (Int32) -> UInt64
    typealias CopySpacesForWindowsFn =
        @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    typealias SetWindowTagsFn =
        @convention(c) (Int32, UInt32, UnsafePointer<UInt64>, Int32) -> Int32
    typealias ClearWindowTagsFn =
        @convention(c) (Int32, UInt32, UnsafePointer<UInt64>, Int32) -> Int32

    nonisolated(unsafe) static let mainConnectionID: MainConnFn =
        sym("SLSMainConnectionID")
    nonisolated(unsafe) static let getActiveSpace: ActiveSpaceFn =
        sym("CGSGetActiveSpace")
    nonisolated(unsafe) static let copySpacesForWindows: CopySpacesForWindowsFn =
        sym("SLSCopySpacesForWindows")
    nonisolated(unsafe) static let setWindowTags: SetWindowTagsFn =
        sym("SLSSetWindowTags")
    nonisolated(unsafe) static let clearWindowTags: ClearWindowTagsFn =
        sym("SLSClearWindowTags")

    private static func sym<T>(_ name: String) -> T {
        guard let p = dlsym(handle, name) else {
            fatalError("SkyLight symbol not found: \(name)")
        }
        return unsafeBitCast(p, to: T.self)
    }
}

// MARK: - AX <-> CGWindowID bridge (the dlsym facet already uses)

/// `_AXUIElementGetWindow` — private ApplicationServices symbol that
/// hands back the CGWindowID for an AX window element. facet's
/// AXFocus.swift relies on the same one.
nonisolated(unsafe) private let axGetWindow: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError)? = {
    guard let h = dlopen(nil, RTLD_NOW),
          let p = dlsym(h, "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(p, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self)
}()

func cgWindowID(of ax: AXUIElement) -> CGWindowID? {
    guard let fn = axGetWindow else { return nil }
    var wid: CGWindowID = 0
    return fn(ax, &wid) == .success ? wid : nil
}

// MARK: - Window enumeration (public CGWindowList)

struct WinInfo {
    let cgID: CGWindowID
    let pid: pid_t
    let owner: String
    let name: String
    let bounds: CGRect
}

func enumerateWindows() -> [WinInfo] {
    let opts: CGWindowListOption = [.optionOnScreenOnly,
                                    .excludeDesktopElements]
    guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
            as? [[String: Any]] else { return [] }
    return raw.compactMap { w in
        guard let id = w[kCGWindowNumber as String] as? CGWindowID,
              let pid = w[kCGWindowOwnerPID as String] as? Int
        else { return nil }
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let name = w[kCGWindowName as String] as? String ?? ""
        var bounds = CGRect.zero
        if let b = w[kCGWindowBounds as String] as? [String: Any] {
            bounds = CGRect(x: b["X"] as? CGFloat ?? 0,
                            y: b["Y"] as? CGFloat ?? 0,
                            width: b["Width"] as? CGFloat ?? 0,
                            height: b["Height"] as? CGFloat ?? 0)
        }
        return WinInfo(cgID: id, pid: pid_t(pid), owner: owner,
                       name: name, bounds: bounds)
    }
}

// MARK: - Find the AXUIElement for a CGWindowID

func axWindow(for cgID: CGWindowID, pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    var winsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
            app, kAXWindowsAttribute as CFString, &winsRef) == .success,
          let wins = winsRef as? [AXUIElement] else { return nil }
    return wins.first { cgWindowID(of: $0) == cgID }
}

// MARK: - AX geometry get / set

func axPosition(_ win: AXUIElement) -> CGPoint? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
            win, kAXPositionAttribute as CFString, &ref) == .success
    else { return nil }
    var pt = CGPoint.zero
    AXValueGetValue(ref as! AXValue, .cgPoint, &pt)
    return pt
}

func axSetPosition(_ win: AXUIElement, _ pt: CGPoint) -> Bool {
    var p = pt
    guard let v = AXValueCreate(.cgPoint, &p) else { return false }
    return AXUIElementSetAttributeValue(
        win, kAXPositionAttribute as CFString, v) == .success
}

func axSetMinimized(_ win: AXUIElement, _ on: Bool) -> Bool {
    AXUIElementSetAttributeValue(
        win, kAXMinimizedAttribute as CFString, on as CFBoolean) == .success
}

func axSetSize(_ win: AXUIElement, _ sz: CGSize) -> Bool {
    var s = sz
    guard let v = AXValueCreate(.cgSize, &s) else { return false }
    return AXUIElementSetAttributeValue(
        win, kAXSizeAttribute as CFString, v) == .success
}

func axSize(_ win: AXUIElement) -> CGSize? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
            win, kAXSizeAttribute as CFString, &ref) == .success
    else { return nil }
    var sz = CGSize.zero
    AXValueGetValue(ref as! AXValue, .cgSize, &sz)
    return sz
}

/// Main display bounds in Quartz coords (top-left origin) — the same
/// coordinate space AX position/size use. (NSScreen.frame is AppKit
/// bottom-left and would be wrong here.)
func quartzScreen() -> CGRect {
    CGDisplayBounds(CGMainDisplayID())
}

/// All active displays' bounds in Quartz coords. Order = main first,
/// then others as macOS reports them.
func allQuartzScreens() -> [CGRect] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids.map { CGDisplayBounds($0) }
}

/// Pick the display whose bounds best contain `point`. Falls back to
/// main if none match (e.g. window dragged off-screen entirely).
func displayContaining(_ point: CGPoint) -> CGRect {
    let screens = allQuartzScreens()
    if let hit = screens.first(where: { $0.contains(point) }) { return hit }
    // Otherwise pick the screen whose center is closest to the point.
    let main = quartzScreen()
    return screens.min(by: { a, b in
        let da = hypot(a.midX - point.x, a.midY - point.y)
        let db = hypot(b.midX - point.x, b.midY - point.y)
        return da < db
    }) ?? main
}

// MARK: - Commands

func cmdList() {
    let cid = SkyLight.mainConnectionID()
    let active = SkyLight.getActiveSpace(cid)
    print("SLS connection id: \(cid)")
    print("active space:      \(active)")
    print("displays (Quartz coords):")
    for (i, s) in allQuartzScreens().enumerated() {
        print("  [\(i)] \(s)")
    }
    print()
    let wins = enumerateWindows()
    print("\(wins.count) on-screen windows:")
    for w in wins.prefix(40) {
        let axOK = axWindow(for: w.cgID, pid: w.pid) != nil ? "AX✓" : "AX✗"
        let b = w.bounds
        print(String(format: "  [%6d] %@ %-18@ %@ (%.0f,%.0f %.0fx%.0f)",
                     Int(w.cgID), axOK, w.owner as NSString,
                     w.name.isEmpty ? "—" : w.name,
                     b.minX, b.minY, b.width, b.height))
    }
}

/// Resolve (info, AX element, original position) for a CGWindowID.
func resolve(_ cgID: CGWindowID) -> (WinInfo, AXUIElement, CGPoint)? {
    guard let info = enumerateWindows().first(where: { $0.cgID == cgID }) else {
        print("no window with id \(cgID)"); return nil
    }
    guard let win = axWindow(for: cgID, pid: info.pid) else {
        print("no AXUIElement for \(cgID) (pid \(info.pid))"); return nil
    }
    guard let orig = axPosition(win) else {
        print("could not read position"); return nil
    }
    return (info, win, orig)
}

/// rift-style 1-pixel-anchor corner park. macOS clamps a fully
/// off-screen window back, so leave ~1px anchored in a screen corner;
/// the rest hangs off-screen. Coords are Quartz (top-left origin) to
/// match AX. `corner` is "BR" (bottom-right) or "BL" (bottom-left).
///
/// rift's hidden_rect_for_corner, ported:
///   BR: top-left = (screen.maxX - 2, screen.maxY - 1)
///   BL: top-left = (screen.minX + 2 - width, screen.maxY - 1)
///
/// Reads position back after setPosition so we can see what macOS
/// actually clamped to — the "requested vs realized" gap is the
/// data we need to decide whether 1px anchor is achievable on this
/// macOS version.
func cmdPark1px(_ cgID: CGWindowID, _ corner: String) {
    guard let (info, win, orig) = resolve(cgID) else { return }
    guard let size = axSize(win) else { print("no size"); return }
    // Multi-display: pick the screen the window currently sits on so
    // we anchor inside its real bounds (main display ≠ origin (0,0)
    // for windows on secondary displays).
    let s = displayContaining(CGPoint(x: orig.x + size.width/2,
                                      y: orig.y + size.height/2))
    let hidden: CGPoint
    switch corner {
    case "BL":
        // window hangs off the left; its right edge anchors ~1px in.
        hidden = CGPoint(x: s.minX + 1 - size.width + 1, y: s.maxY - 1)
    default: // BR
        // window hangs off the bottom-right; its top-left anchors ~1px.
        hidden = CGPoint(x: s.maxX - 1 - 1, y: s.maxY - 1)
    }
    print("[\(corner)] park \(info.owner) size \(Int(size.width))x\(Int(size.height))")
    print("  screen(quartz) \(s)")
    print("  orig position: \(orig)")
    print("  requested top-left: \(hidden)")
    print("  setPosition → \(axSetPosition(win, hidden))")
    // Re-read so we see what macOS actually clamped to.
    if let actual = axPosition(win) {
        print("  actual  top-left: \(actual)")
        let dx = actual.x - hidden.x
        let dy = actual.y - hidden.y
        print("  clamp delta: dx=\(dx), dy=\(dy)")
        // Compute visible rect (window ∩ screen) in Quartz coords.
        let winRect = CGRect(origin: actual, size: size)
        let vis = winRect.intersection(s)
        print("  visible rect: \(vis)  → \(Int(vis.width))×\(Int(vis.height)) pts")
    }
    print("  → OBSERVE 5s")
    Thread.sleep(forTimeInterval: 5)
    print("  restore to \(orig): \(axSetPosition(win, orig))")
}

/// Probe: try progressively more extreme positions to find macOS's
/// clamp boundary. For each candidate, set and read back. Tells us
/// the minimum visible-pixel guarantee macOS enforces — which is
/// what we actually need to know to size the 1-px-anchor strategy.
func cmdClampProbe(_ cgID: CGWindowID) {
    guard let (info, win, orig) = resolve(cgID) else { return }
    guard let size = axSize(win) else { print("no size"); return }
    let s = displayContaining(CGPoint(x: orig.x + size.width/2,
                                      y: orig.y + size.height/2))
    print("[clamp-probe] \(info.owner) \(Int(size.width))x\(Int(size.height))")
    print("  screen \(s)")
    // Candidate top-left positions in Quartz coords, all aimed at
    // bottom-right corner with varying offsets.
    let candidates: [(String, CGPoint)] = [
        ("BR maxX-2,   maxY-1",  CGPoint(x: s.maxX - 2,        y: s.maxY - 1)),
        ("BR maxX-1,   maxY-1",  CGPoint(x: s.maxX - 1,        y: s.maxY - 1)),
        ("BR maxX,     maxY",    CGPoint(x: s.maxX,            y: s.maxY)),
        ("BR maxX+100, maxY+100",CGPoint(x: s.maxX + 100,      y: s.maxY + 100)),
        ("BR maxX-w/2, maxY-h/2",CGPoint(x: s.maxX - size.width/2,
                                        y: s.maxY - size.height/2)),
        ("BR maxX-w+1, maxY-h+1",CGPoint(x: s.maxX - size.width + 1,
                                        y: s.maxY - size.height + 1)),
        ("BR -10000, -10000",    CGPoint(x: -10000,            y: -10000)),
    ]
    for (label, pt) in candidates {
        _ = axSetPosition(win, pt)
        Thread.sleep(forTimeInterval: 0.3)
        guard let actual = axPosition(win) else { print("  \(label): no read"); continue }
        let winRect = CGRect(origin: actual, size: size)
        let vis = winRect.intersection(s)
        print(String(format: "  %-26@ req=(%6.0f,%6.0f) act=(%6.0f,%6.0f) Δ=(%+6.0f,%+6.0f) vis=%4.0f×%4.0f",
                     label as NSString,
                     pt.x, pt.y, actual.x, actual.y,
                     actual.x - pt.x, actual.y - pt.y,
                     vis.width, vis.height))
    }
    print("  restore to \(orig): \(axSetPosition(win, orig))")
}

/// Method resize-zero: AX kAXSize → (0, 0). Probes whether macOS
/// (or the app) enforces a minimum size — many apps publish a
/// minimum via NSWindow.minSize, in which case the call is clamped
/// up to that limit and "hide via size" fails. Reads size back to
/// see what was actually applied.
func cmdParkZero(_ cgID: CGWindowID) {
    guard let (info, win, orig) = resolve(cgID) else { return }
    guard let origSize = axSize(win) else { print("no size"); return }
    print("[resize-zero] \(info.owner) orig \(Int(origSize.width))x\(Int(origSize.height)) at \(orig)")
    // Try a sequence of progressively smaller sizes so we can spot
    // the min-size clamp boundary.
    let candidates: [CGSize] = [.zero, CGSize(width: 1, height: 1),
                                CGSize(width: 10, height: 10),
                                CGSize(width: 50, height: 50),
                                CGSize(width: 100, height: 100)]
    for c in candidates {
        _ = axSetSize(win, c)
        Thread.sleep(forTimeInterval: 0.5)
        guard let actual = axSize(win) else { continue }
        print(String(format: "  req=(%4.0fx%4.0f)  act=(%4.0fx%4.0f)",
                     c.width, c.height, actual.width, actual.height))
    }
    print("  → OBSERVE 5s: smallest-size window visible? animation?")
    Thread.sleep(forTimeInterval: 5)
    _ = axSetSize(win, origSize)
    print("  restore size \(origSize): done")
}

/// Method minimize: AX kAXMinimized. Goes to the Dock — disappears
/// from screen + Mission Control, stays in Cmd-Tab as minimized.
/// Has a genie animation though.
func cmdParkMinimize(_ cgID: CGWindowID) {
    guard let (info, win, _) = resolve(cgID) else { return }
    print("[minimize] \(info.owner)")
    print("  minimize: \(axSetMinimized(win, true))")
    print("  → OBSERVE 5s: gone to Dock? animation? Mission Control?")
    Thread.sleep(forTimeInterval: 5)
    print("  unminimize: \(axSetMinimized(win, false))")
}

/// Method SLS tag: experimental. SLSSetWindowTags with a "hidden"
/// tag bit. Tag semantics are reverse-engineered — this probe just
/// reports whether the call succeeds; visual effect is observed.
func cmdParkTag(_ cgID: CGWindowID) {
    let cid = SkyLight.mainConnectionID()
    // Tag bit 0x2 is commonly the "sticky/hidden"-ish bit in CGS
    // window tag lore; we just probe one and observe.
    var tags: UInt64 = 0x2
    let r = SkyLight.setWindowTags(cid, cgID, &tags, 64)
    print("[sls-tag] SLSSetWindowTags(\(cgID), 0x2) → \(r)")
    print("  → OBSERVE 5s: any visual change?")
    Thread.sleep(forTimeInterval: 5)
    let r2 = SkyLight.clearWindowTags(cid, cgID, &tags, 64)
    print("  clear → \(r2)")
}

func cmdFocus(_ cgID: CGWindowID) {
    guard let info = enumerateWindows().first(where: { $0.cgID == cgID }) else {
        print("no window with id \(cgID)"); return
    }
    guard let win = axWindow(for: cgID, pid: info.pid) else {
        print("could not get AXUIElement"); return
    }
    let raise = AXUIElementPerformAction(win, kAXRaiseAction as CFString)
    NSRunningApplication(processIdentifier: info.pid)?
        .activate(options: [])
    print("focus [\(cgID)] \(info.owner): raise=\(raise == .success)")
}

// MARK: - Entry

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "list"

if !AXIsProcessTrusted() {
    print("⚠️  Accessibility NOT granted to this terminal.")
    print("    System Settings → Privacy & Security → Accessibility →")
    print("    add your terminal app, then re-run.")
    let opts = ["AXTrustedCheckOptionPrompt": true]
    _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
    exit(1)
}

switch cmd {
case "list":
    cmdList()
case "park-1px":
    guard args.count >= 2, let id = UInt32(args[1]) else {
        print("usage: native-spike park-1px <cgWindowID> [BR|BL]"); exit(2)
    }
    cmdPark1px(id, args.count >= 3 ? args[2] : "BR")
case "clamp-probe":
    guard args.count >= 2, let id = UInt32(args[1]) else {
        print("usage: native-spike clamp-probe <cgWindowID>"); exit(2)
    }
    cmdClampProbe(id)
case "park-min":
    guard args.count >= 2, let id = UInt32(args[1]) else {
        print("usage: native-spike park-min <cgWindowID>"); exit(2)
    }
    cmdParkMinimize(id)
case "park-zero":
    guard args.count >= 2, let id = UInt32(args[1]) else {
        print("usage: native-spike park-zero <cgWindowID>"); exit(2)
    }
    cmdParkZero(id)
case "park-tag":
    guard args.count >= 2, let id = UInt32(args[1]) else {
        print("usage: native-spike park-tag <cgWindowID>"); exit(2)
    }
    cmdParkTag(id)
case "focus":
    guard args.count >= 2, let id = UInt32(args[1]) else {
        print("usage: native-spike focus <cgWindowID>"); exit(2)
    }
    cmdFocus(id)
default:
    print("usage: native-spike [list | park-1px <id> [BR|BL] | clamp-probe <id> | park-min <id> | park-zero <id> | park-tag <id> | focus <id>]")
    exit(2)
}
