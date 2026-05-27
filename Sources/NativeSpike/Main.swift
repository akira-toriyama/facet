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
    typealias CopyManagedDisplaySpacesFn =
        @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias MoveWindowsToManagedSpaceFn =
        @convention(c) (Int32, CFArray, UInt64) -> Void
    // Add/remove pair — yabai's main path for cross-Space window move.
    typealias AddWindowsToSpacesFn =
        @convention(c) (Int32, CFArray, CFArray) -> Void
    typealias RemoveWindowsFromSpacesFn =
        @convention(c) (Int32, CFArray, CFArray) -> Void

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
    nonisolated(unsafe) static let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn =
        sym("SLSCopyManagedDisplaySpaces")
    nonisolated(unsafe) static let moveWindowsToManagedSpace: MoveWindowsToManagedSpaceFn =
        sym("SLSMoveWindowsToManagedSpace")
    // optSym: nil if symbol missing on this macOS — for variants that may
    // not exist on all versions.
    private static func optSym<T>(_ name: String) -> T? {
        guard let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
    nonisolated(unsafe) static let addWindowsToSpaces: AddWindowsToSpacesFn? =
        optSym("SLSAddWindowsToSpaces") ?? optSym("CGSAddWindowsToSpaces")
    nonisolated(unsafe) static let removeWindowsFromSpaces: RemoveWindowsFromSpacesFn? =
        optSym("SLSRemoveWindowsFromSpaces") ?? optSym("CGSRemoveWindowsFromSpaces")

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
private let axGetWindow: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError)? = {
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
    let before = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
    print("[focus] target=\(info.owner) pid=\(info.pid) cgID=\(cgID)")
    print("  before frontmost: \(before)")
    let raise = AXUIElementPerformAction(win, kAXRaiseAction as CFString)
    let act = NSRunningApplication(processIdentifier: info.pid)?
        .activate(options: []) ?? false
    // give macOS a moment to update frontmostApplication
    Thread.sleep(forTimeInterval: 0.3)
    let after = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
    print("  AX raise:    \(raise == .success)")
    print("  NSApp activate: \(act)")
    print("  after frontmost:  \(after)")
    let success = (after == info.owner)
    print("  → focus moved to target? \(success ? "YES ✓" : "NO ✗")")
}

// MARK: - Multi-window park (app-grouped)

/// Park every visible window owned by the same app as `cgID`. Used
/// to validate the "hide one app at a time" path the workspace
/// switcher will call. Restores all windows after observe time.
func cmdParkApp(_ cgID: CGWindowID) {
    let all = enumerateWindows()
    guard let anchor = all.first(where: { $0.cgID == cgID }) else {
        print("no window with id \(cgID)"); return
    }
    let sameApp = all.filter { $0.pid == anchor.pid }
    print("[park-app] \(anchor.owner) (pid \(anchor.pid)) — \(sameApp.count) windows")
    // Resolve AX element + original position + size for each.
    var ctx: [(WinInfo, AXUIElement, CGPoint, CGSize)] = []
    for w in sameApp {
        guard let ax = axWindow(for: w.cgID, pid: w.pid),
              let pos = axPosition(ax),
              let sz = axSize(ax) else {
            print("  skip [\(w.cgID)] (no AX)"); continue
        }
        ctx.append((w, ax, pos, sz))
    }
    // Park each at its display's bottom-right (1×41 sliver).
    for (w, ax, _, sz) in ctx {
        let s = displayContaining(CGPoint(x: w.bounds.midX, y: w.bounds.midY))
        let hidden = CGPoint(x: s.maxX - 1, y: s.maxY - 1)
        let ok = axSetPosition(ax, hidden)
        print("  park [\(w.cgID)] \(Int(sz.width))x\(Int(sz.height)) → \(hidden): \(ok)")
    }
    print("  → OBSERVE 5s: all \(ctx.count) windows hidden in BR corner?")
    Thread.sleep(forTimeInterval: 5)
    for (w, ax, orig, _) in ctx {
        _ = axSetPosition(ax, orig)
        print("  restore [\(w.cgID)] → \(orig)")
    }
}

// MARK: - Per-window space query (SLSCopySpacesForWindows)

/// For each given CGWindowID, ask SLS which macOS Spaces it appears
/// on. SLSCopySpacesForWindows takes (cid, mask, [windowIDs]) and
/// returns an array of space ids. Mask 0x7 = all space types.
func cmdSpaces(_ cgIDs: [CGWindowID]) {
    let cid = SkyLight.mainConnectionID()
    let active = SkyLight.getActiveSpace(cid)
    print("[spaces] active space = \(active)")
    print("  query mask = 0x7 (all space types)")
    // Build a CFArray of NSNumber CGWindowIDs.
    let nums = cgIDs.map { NSNumber(value: $0) }
    let arr = nums as CFArray
    guard let result = SkyLight.copySpacesForWindows(cid, 0x7, arr)?
            .takeRetainedValue() as? [Any] else {
        print("  SLSCopySpacesForWindows returned nil")
        return
    }
    print("  raw result: \(result)")
    print("  (one-to-one mapping by index; ids referencing single windows")
    print("   typically return that window's space, but SLS coalesces —")
    print("   so result.count may not equal cgIDs.count)")
    for (i, id) in cgIDs.enumerated() {
        // Find the window owner for nicer output.
        let owner = enumerateWindows().first(where: { $0.cgID == id })?
            .owner ?? "?"
        print("  cgID \(id) (\(owner)): see raw result for actual space mapping")
        _ = i
    }
}

// MARK: - macOS Spaces enumeration + move

/// `SLSCopyManagedDisplaySpaces(cid)` returns an array of
/// per-display dicts; each dict has a "Spaces" key whose value is
/// an array of space dicts (each with "id64", "type", "uuid",
/// "ManagedSpaceID"). type = 0 (user) / 4 (fullscreen).
func cmdListSpaces() {
    let cid = SkyLight.mainConnectionID()
    let active = SkyLight.getActiveSpace(cid)
    print("[spaces] SLS connection id: \(cid)")
    print("[spaces] active space id:   \(active)")
    guard let result = SkyLight.copyManagedDisplaySpaces(cid)?
            .takeRetainedValue() as? [[String: Any]] else {
        print("[spaces] SLSCopyManagedDisplaySpaces returned nil")
        return
    }
    for (di, disp) in result.enumerated() {
        let dispID = disp["Display Identifier"] as? String ?? "?"
        print("[spaces] display [\(di)] id=\(dispID)")
        guard let spaces = disp["Spaces"] as? [[String: Any]] else {
            print("    (no Spaces key)"); continue
        }
        for (si, sp) in spaces.enumerated() {
            let id64 = sp["id64"] as? UInt64 ?? 0
            let type = sp["type"] as? Int ?? -1
            let uuid = sp["uuid"] as? String ?? "?"
            let mgd = sp["ManagedSpaceID"] as? Int ?? -1
            let typeStr: String = {
                switch type {
                case 0: return "user"
                case 4: return "fullscreen"
                default: return "type=\(type)"
                }
            }()
            let activeMark = (id64 == active) ? " ← ACTIVE" : ""
            print("    [\(si)] id64=\(id64) ManagedSpaceID=\(mgd) (\(typeStr)) uuid=\(uuid)\(activeMark)")
        }
    }
}

/// Test the cross-Space window move under SIP-on.
///
/// Calls `SLSMoveWindowsToManagedSpace(cid, [cgID], spaceID)`. The
/// function is `void` so we can't read a return code; we verify by
/// re-querying `SLSCopySpacesForWindows` afterwards and reporting
/// whether the window now reports the target Space.
func cmdMoveSpace(_ cgID: CGWindowID, _ spaceID: UInt64) {
    let cid = SkyLight.mainConnectionID()
    let active = SkyLight.getActiveSpace(cid)

    // Find window for the nicer output.
    let info = enumerateWindows().first(where: { $0.cgID == cgID })
    let owner = info?.owner ?? "?"
    print("[move-space] cgID=\(cgID) owner=\(owner)")
    print("[move-space] active space id:   \(active)")
    print("[move-space] target  space id:  \(spaceID)")

    // Query current Space(s) before move.
    let nums = [NSNumber(value: cgID)] as CFArray
    let before = SkyLight.copySpacesForWindows(cid, 0x7, nums)?
        .takeRetainedValue() as? [Any] ?? []
    print("[move-space] BEFORE: SLSCopySpacesForWindows → \(before)")

    print("[move-space] calling SLSMoveWindowsToManagedSpace …")
    SkyLight.moveWindowsToManagedSpace(cid, [NSNumber(value: cgID)] as CFArray, spaceID)
    print("[move-space] call returned (no rc — this is a void API)")

    // Give the system a moment, then re-query.
    Thread.sleep(forTimeInterval: 0.5)
    let after = SkyLight.copySpacesForWindows(cid, 0x7, nums)?
        .takeRetainedValue() as? [Any] ?? []
    print("[move-space] AFTER:  SLSCopySpacesForWindows → \(after)")

    let beforeSet = Set((before as? [UInt64]) ?? before.compactMap { ($0 as? NSNumber)?.uint64Value })
    let afterSet = Set((after as? [UInt64]) ?? after.compactMap { ($0 as? NSNumber)?.uint64Value })
    if beforeSet == afterSet {
        print("[move-space] ❌ NO CHANGE — Space membership did not move")
        print("              (Apple likely no-ops this API for non-Apple processes,")
        print("               or requires SIP off + scripting addition for cross-app moves)")
    } else if afterSet.contains(spaceID) {
        print("[move-space] ✅ MOVED — window now reports target space \(spaceID)")
    } else {
        print("[move-space] ⚠️  CHANGED but not to target: before=\(beforeSet) after=\(afterSet)")
    }
}

/// yabai's main path: pair-call CGS{Add,Remove}WindowsToSpaces with
/// from/to Space arrays. Tests whether the ADD/REMOVE variant gets
/// past the SkyLight gate that silently no-op'd
/// `SLSMoveWindowsToManagedSpace`.
func cmdAddRemoveSpace(_ cgID: CGWindowID, from: UInt64, to: UInt64) {
    let cid = SkyLight.mainConnectionID()
    let active = SkyLight.getActiveSpace(cid)
    let info = enumerateWindows().first(where: { $0.cgID == cgID })
    let owner = info?.owner ?? "?"

    guard let addFn = SkyLight.addWindowsToSpaces,
          let removeFn = SkyLight.removeWindowsFromSpaces else {
        print("[add-remove] symbols not found on this macOS — abort")
        print("  add:    \(SkyLight.addWindowsToSpaces == nil ? "MISSING" : "OK")")
        print("  remove: \(SkyLight.removeWindowsFromSpaces == nil ? "MISSING" : "OK")")
        return
    }

    print("[add-remove] cgID=\(cgID) owner=\(owner)")
    print("[add-remove] active space id:   \(active)")
    print("[add-remove] FROM space id:     \(from)")
    print("[add-remove] TO   space id:     \(to)")

    let nums = [NSNumber(value: cgID)] as CFArray
    let fromArr = [NSNumber(value: from)] as CFArray
    let toArr = [NSNumber(value: to)] as CFArray

    let before = SkyLight.copySpacesForWindows(cid, 0x7, nums)?
        .takeRetainedValue() as? [Any] ?? []
    print("[add-remove] BEFORE: SLSCopySpacesForWindows → \(before)")

    print("[add-remove] calling SLSAddWindowsToSpaces([\(cgID)], [\(to)]) …")
    addFn(cid, nums, toArr)
    print("[add-remove] calling SLSRemoveWindowsFromSpaces([\(cgID)], [\(from)]) …")
    removeFn(cid, nums, fromArr)

    Thread.sleep(forTimeInterval: 0.5)
    let after = SkyLight.copySpacesForWindows(cid, 0x7, nums)?
        .takeRetainedValue() as? [Any] ?? []
    print("[add-remove] AFTER:  SLSCopySpacesForWindows → \(after)")

    let beforeSet = Set((before as? [UInt64]) ?? before.compactMap { ($0 as? NSNumber)?.uint64Value })
    let afterSet = Set((after as? [UInt64]) ?? after.compactMap { ($0 as? NSNumber)?.uint64Value })
    if beforeSet == afterSet {
        print("[add-remove] ❌ NO CHANGE — Space membership did not move")
    } else if afterSet.contains(to) && !afterSet.contains(from) {
        print("[add-remove] ✅ MOVED — window now reports target space \(to)")
    } else {
        print("[add-remove] ⚠️  CHANGED but unexpected: before=\(beforeSet) after=\(afterSet)")
    }
}

/// Try the singular variant if it exists. Many macOS versions only
/// have the plural `SLSMoveWindowsToManagedSpace`; this is a probe.
func cmdMoveSpaceSingular(_ cgID: CGWindowID, _ spaceID: UInt64) {
    typealias SingularFn =
        @convention(c) (Int32, UInt32, UInt64) -> Void
    guard let p = dlsym(SkyLight.handle, "SLSMoveWindowToManagedSpace") else {
        print("[singular] SLSMoveWindowToManagedSpace not found on this macOS")
        return
    }
    let fn = unsafeBitCast(p, to: SingularFn.self)
    let cid = SkyLight.mainConnectionID()
    let nums = [NSNumber(value: cgID)] as CFArray
    let before = SkyLight.copySpacesForWindows(cid, 0x7, nums)?
        .takeRetainedValue() as? [Any] ?? []
    print("[singular] BEFORE: SLSCopySpacesForWindows → \(before)")
    print("[singular] calling SLSMoveWindowToManagedSpace(cid, \(cgID), \(spaceID)) …")
    fn(cid, cgID, spaceID)
    Thread.sleep(forTimeInterval: 0.5)
    let after = SkyLight.copySpacesForWindows(cid, 0x7, nums)?
        .takeRetainedValue() as? [Any] ?? []
    print("[singular] AFTER:  SLSCopySpacesForWindows → \(after)")
    let beforeSet = Set((before as? [UInt64]) ?? before.compactMap { ($0 as? NSNumber)?.uint64Value })
    let afterSet = Set((after as? [UInt64]) ?? after.compactMap { ($0 as? NSNumber)?.uint64Value })
    if beforeSet == afterSet {
        print("[singular] ❌ NO CHANGE")
    } else if afterSet.contains(spaceID) {
        print("[singular] ✅ MOVED")
    } else {
        print("[singular] ⚠️  CHANGED but not to target")
    }
}

/// macOS 14+ combined add+remove call. Symbol may not exist on older
/// systems — skip cleanly if so.
func cmdCombinedSpace(_ cgID: CGWindowID, from: UInt64, to: UInt64) {
    typealias CombinedFn =
        @convention(c) (Int32, UInt64, CFArray, UInt64) -> Void
    guard let p = dlsym(SkyLight.handle, "SLSSpaceAddWindowsAndRemoveFromSpaces") else {
        print("[combined] SLSSpaceAddWindowsAndRemoveFromSpaces not found — abort")
        return
    }
    let fn = unsafeBitCast(p, to: CombinedFn.self)
    let cid = SkyLight.mainConnectionID()
    let nums = [NSNumber(value: cgID)] as CFArray
    let before = SkyLight.copySpacesForWindows(cid, 0x7, nums)?
        .takeRetainedValue() as? [Any] ?? []
    print("[combined] BEFORE: SLSCopySpacesForWindows → \(before)")
    print("[combined] calling SLSSpaceAddWindowsAndRemoveFromSpaces(cid, \(to), [\(cgID)], \(from)) …")
    fn(cid, to, nums, from)
    Thread.sleep(forTimeInterval: 0.5)
    let after = SkyLight.copySpacesForWindows(cid, 0x7, nums)?
        .takeRetainedValue() as? [Any] ?? []
    print("[combined] AFTER:  SLSCopySpacesForWindows → \(after)")
    let beforeSet = Set((before as? [UInt64]) ?? before.compactMap { ($0 as? NSNumber)?.uint64Value })
    let afterSet = Set((after as? [UInt64]) ?? after.compactMap { ($0 as? NSNumber)?.uint64Value })
    if beforeSet == afterSet {
        print("[combined] ❌ NO CHANGE")
    } else if afterSet.contains(to) && !afterSet.contains(from) {
        print("[combined] ✅ MOVED")
    } else {
        print("[combined] ⚠️  CHANGED but unexpected")
    }
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
case "park-app":
    guard args.count >= 2, let id = UInt32(args[1]) else {
        print("usage: native-spike park-app <cgWindowID>  (parks every window of that app)"); exit(2)
    }
    cmdParkApp(id)
case "spaces":
    guard args.count >= 2 else {
        print("usage: native-spike spaces <cgWindowID> [<cgWindowID> ...]"); exit(2)
    }
    let ids = args.dropFirst().compactMap { UInt32($0) }
    guard !ids.isEmpty else {
        print("no valid CGWindowIDs given"); exit(2)
    }
    cmdSpaces(Array(ids))
case "list-spaces":
    cmdListSpaces()
case "move-space":
    guard args.count >= 3,
          let cgID = UInt32(args[1]),
          let target = UInt64(args[2]) else {
        print("usage: native-spike move-space <cgWindowID> <targetSpaceID>")
        print("  (run `native-spike list-spaces` first to get target Space id64)")
        exit(2)
    }
    cmdMoveSpace(cgID, target)
case "add-remove-space":
    guard args.count >= 4,
          let cgID = UInt32(args[1]),
          let from = UInt64(args[2]),
          let to = UInt64(args[3]) else {
        print("usage: native-spike add-remove-space <cgID> <fromSpaceID> <toSpaceID>")
        exit(2)
    }
    cmdAddRemoveSpace(cgID, from: from, to: to)
case "move-singular":
    guard args.count >= 3,
          let cgID = UInt32(args[1]),
          let target = UInt64(args[2]) else {
        print("usage: native-spike move-singular <cgID> <targetSpaceID>")
        exit(2)
    }
    cmdMoveSpaceSingular(cgID, target)
case "combined-space":
    guard args.count >= 4,
          let cgID = UInt32(args[1]),
          let from = UInt64(args[2]),
          let to = UInt64(args[3]) else {
        print("usage: native-spike combined-space <cgID> <fromSpaceID> <toSpaceID>")
        exit(2)
    }
    cmdCombinedSpace(cgID, from: from, to: to)
default:
    print("usage: native-spike [list | list-spaces | park-1px <id> [BR|BL] | clamp-probe <id> | park-min <id> | park-zero <id> | park-tag <id> | park-app <id> | spaces <id...> | move-space <id> <spaceID> | add-remove-space <id> <from> <to> | move-singular <id> <spaceID> | combined-space <id> <from> <to> | focus <id>]")
    exit(2)
}
