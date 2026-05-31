// FacetCore — backend-neutral state models.
//
// These are the types every `WindowBackend` translates *into*. Views
// only ever see these — they never touch rift / AX / CGS types
// directly. See docs/architecture.md for layer rules.

import CoreGraphics

/// Stable handle for a window across backend queries.
///
/// Backed by the macOS window-server id (CGS), which rift reports as
/// `window_server_id` and the native adapter will obtain via
/// `_AXUIElementGetWindow`. Equality and hashing are by `serverID`
/// alone — the same window across two `workspaces()` calls compares
/// equal.
public struct WindowID: Hashable, Sendable {
    public let serverID: Int
    public init(serverID: Int) { self.serverID = serverID }
}

/// One window in a workspace.
///
/// `pid` and `title` are kept on the model because AX focus needs
/// both alongside `serverID` to disambiguate same-id race conditions.
public extension Sequence where Element == Window {
    /// Auto-pick a sensible focus target within this window list:
    /// the already-focused window first, then the oldest by
    /// `serverID` (= the WS's longest-resident window, a stable
    /// fallback). `nil` for an empty input.
    ///
    /// Shared between the sidebar's optimistic header-click
    /// highlight and `WorkspaceCatalog.autoFocusTarget`'s fallback
    /// so the two routes can't drift — when the catalog's
    /// `lastFocusedOnLeave` snapshot misses (stale / never
    /// recorded), the window the user lands on is the same one
    /// the sidebar pre-highlighted.
    func predictedFocus() -> Window? {
        if let focused = first(where: { $0.isFocused }) { return focused }
        return self.min(by: { $0.id.serverID < $1.id.serverID })
    }
}

public struct Window: Sendable {
    public let id: WindowID
    public let pid: Int
    public let appName: String
    /// Bundle identifier of the owning app (e.g. `com.apple.finder`),
    /// resolved by the adapter from `pid`. `nil` when the app has no
    /// bundle id (rare) or it couldn't be resolved. Used by config
    /// `[[exclude]]` rules to match windows by app.
    public let bundleId: String?
    public let title: String
    public let isFocused: Bool
    public let isFloating: Bool
    /// Where the user perceives the window on its owning workspace.
    /// For the active WS this is the live on-screen frame. For
    /// inactive WSs the adapter computes the would-be frame the
    /// window will occupy on next switch — BSP tile slot in
    /// `"bsp"` mode, full active rect in `"stack"` mode, the
    /// recorded pre-park position (+ current size) in `"float"`
    /// mode or for floating windows. Falls back to the live frame
    /// when no would-be info is available (fresh window never
    /// parked). `nil` when the backend cannot supply geometry.
    public let frame: CGRect?
    /// Whether the window currently has a visible spot on any
    /// display — equivalent to `CGWindowList`'s
    /// `kCGWindowIsOnscreen`. `false` when the window lives on a
    /// different macOS Space, is minimized to the Dock, or has
    /// been hidden via Cmd+H. The catalog uses this to gate **new
    /// window entries** only (off-screen-on-first-sight windows
    /// stay unmanaged); existing windows in the map are kept
    /// regardless of this flag so a Space switch / minimize
    /// doesn't lose the WS assignment. See memory
    /// `facet-macos-spaces-coexistence`.
    public let isOnscreen: Bool
    /// Whether this window occupies the master slot of its workspace
    /// — i.e. it is first in the workspace's tiling order
    /// (`order[0]`). Only meaningful for master-stack layouts
    /// (tall / wide / centered); the right-click menu uses it to hide
    /// "Promote to master" on the window that is already the master.
    /// `false` for floating windows and layouts without a master.
    public let isMaster: Bool

    public init(id: WindowID,
                pid: Int,
                appName: String,
                title: String,
                isFocused: Bool,
                isFloating: Bool,
                frame: CGRect?,
                isOnscreen: Bool = true,
                isMaster: Bool = false,
                bundleId: String? = nil) {
        self.id = id
        self.pid = pid
        self.appName = appName
        self.bundleId = bundleId
        self.title = title
        self.isFocused = isFocused
        self.isFloating = isFloating
        self.frame = frame
        self.isOnscreen = isOnscreen
        self.isMaster = isMaster
    }
}

/// One workspace (virtual desktop) returned by the backend.
public struct Workspace: Sendable {
    public let index: Int
    public let name: String
    public let isActive: Bool
    /// Backend-defined string (e.g. rift's "master_stack", "bsp", …).
    /// Views treat this as opaque; the backend's `layoutModes` lists
    /// the valid values and `windowMenu` knows how to act on them.
    public let layoutMode: String
    public let windows: [Window]

    public init(index: Int,
                name: String,
                isActive: Bool,
                layoutMode: String,
                windows: [Window]) {
        self.index = index
        self.name = name
        self.isActive = isActive
        self.layoutMode = layoutMode
        self.windows = windows
    }
}
