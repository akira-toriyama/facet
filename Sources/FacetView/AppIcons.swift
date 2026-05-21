// PID → app icon cache. Both the tree and grid views render the
// owning app's Dock icon next to each window; `NSRunningApplication`
// returns a fresh `NSImage` per call which we'd otherwise re-fetch
// on every redraw.

import AppKit

@MainActor
public enum AppIcons {
    private static var cache: [Int: NSImage] = [:]

    public static func icon(forPID pid: Int) -> NSImage? {
        if let cached = cache[pid] { return cached }
        guard let img = NSRunningApplication(
            processIdentifier: pid_t(pid))?.icon
        else { return nil }
        cache[pid] = img
        return img
    }
}
