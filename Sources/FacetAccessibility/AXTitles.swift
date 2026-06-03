// Resolve window titles via Accessibility for the many apps that
// give an empty `title` (Chrome, Code, several Electron apps).
// One AX pass per *app* (not per window) — we batch the lookup by
// pid so an app with 12 windows costs us one AX round-trip, not 12.
// Short TTL cache to keep the cost off the refresh hot path.
//
// **Call only from `cliQueue`** (serial, off-main); the cache is
// single-threaded by that contract.
//
// Shared with FacetAdapterNative via this module (extracted out
// of FacetAdapterRift at M5).

import ApplicationServices
import Foundation
import FacetCore

public enum AXTitles {
    nonisolated(unsafe)
    private static var cache: [Int: (title: String, at: Date)] = [:]
    private static let ttl: TimeInterval = 3

    /// Returns `WindowID -> resolved title` for windows the backend
    /// left blank. Windows with non-empty titles are skipped (the
    /// backend's value wins). Failure to resolve is recorded in the
    /// cache too so we don't re-query the same uncooperative app
    /// every refresh.
    public static func resolve(_ workspaces: [Workspace]) -> [WindowID: String] {
        var out: [WindowID: String] = [:]
        var needByPid: [Int: [WindowID]] = [:]
        let now = Date()
        for ws in workspaces {
            for w in ws.windows where w.title.isEmpty {
                let id = w.id
                if let c = cache[id.serverID],
                   now.timeIntervalSince(c.at) < ttl {
                    if !c.title.isEmpty { out[id] = c.title }
                } else {
                    needByPid[w.pid, default: []].append(id)
                }
            }
        }
        guard let getWin = axGetWindow, !needByPid.isEmpty else { return out }
        for (pid, ids) in needByPid {
            let app = AXUIElementCreateApplication(pid_t(pid))
            AXUIElementSetMessagingTimeout(app, 0.25)
            var wr: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(
                    app, kAXWindowsAttribute as CFString, &wr) == .success,
                let wins = wr as? [AXUIElement]
            else { continue }
            // serverID -> title, computed once per app.
            var bySID: [Int: String] = [:]
            for win in wins {
                var cg: UInt32 = 0
                guard getWin(win, &cg) == .success else { continue }
                var t: CFTypeRef?
                AXUIElementCopyAttributeValue(
                    win, kAXTitleAttribute as CFString, &t)
                bySID[Int(cg)] = (t as? String) ?? ""
            }
            for id in ids {
                let title = bySID[id.serverID] ?? ""
                cache[id.serverID] = (title, now)
                if !title.isEmpty { out[id] = title }
            }
        }
        return out
    }
}
