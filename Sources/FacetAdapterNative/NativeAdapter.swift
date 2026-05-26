// `WindowBackend` conformance using only AX + public macOS APIs
// (no `rift-cli`, no SLS, no SIP-off injection). Phase α–ε grows
// each method from a no-op stub into a real implementation; this
// file is the seam.
//
// Phase plan (memory: facet-architecture-decisions):
//   α  — virtual workspace state self-managed; focus
//   β  — window move across workspaces; off-screen park/unpark
//        (`anchor` + `minimize` hide methods, memory:
//        native-window-hide-methods)
//   γ  — tiling layout engines
//   δ  — display reconfigure handling, geometry persistence
//   ε  — `FacetAdapterRift` deprecation
//
// Today (this file's birthday) we land a skeleton: every
// `WindowBackend` requirement is satisfied so the type is usable
// where `RiftAdapter` is. No backend selection wiring yet —
// `Main.swift` still constructs `RiftAdapter()`. The selection
// flip lands in the PR that fills in the Phase α queries.

import ApplicationServices
import Foundation
import FacetCore

public final class NativeAdapter: WindowBackend, @unchecked Sendable {
    public let name = "native"

    /// Tentative layout-mode set — revisited at Phase γ when the
    /// tiling engines land. Keeping non-empty so the right-click
    /// menu builder doesn't trip over an empty list during the
    /// transition window where some views ask the backend's
    /// supported modes at startup.
    public let layoutModes = ["bsp", "stack"]

    // MARK: - Self-managed workspace state (Phase α)

    /// Index (1-based, user-facing) of the active workspace.
    /// Phase α implements `switchWorkspace` by mutating this and
    /// re-emitting `BackendEvent.refreshNeeded`.
    private var activeIndex: Int = 1

    /// Snapshot of workspaces, rebuilt from config on reload.
    /// Each entry's `windows` is empty in this PR — populating it
    /// from CGWindowList comes with the next phase slice
    /// (Phase α window-catalog).
    private var workspaceList: [Workspace] = []

    // MARK: - Event / error streams

    private let eventStream: AsyncStream<BackendEvent>
    private let eventContinuation: AsyncStream<BackendEvent>.Continuation
    private let errorStream: AsyncStream<String>
    private let errorContinuation: AsyncStream<String>.Continuation

    /// Init with config so workspace count + names come from the
    /// user's `[workspace]` section. The (default = 5) fallback in
    /// FacetConfig keeps a vanilla `~/.config/facet/config.toml`
    /// usable out of the box.
    public init(config: FacetConfig) {
        var ec: AsyncStream<BackendEvent>.Continuation!
        self.eventStream = AsyncStream { c in ec = c }
        self.eventContinuation = ec
        var errC: AsyncStream<String>.Continuation!
        self.errorStream = AsyncStream { c in errC = c }
        self.errorContinuation = errC

        self.workspaceList = Self.buildWorkspaces(
            from: config, activeIndex: 1)

        // AX permission is the foundation of every native-backend
        // operation (focus, title resolution, window enumeration).
        // Same surface as RiftAdapter so the user sees the same
        // hint regardless of which backend is active.
        if !AXIsProcessTrusted() {
            DispatchQueue.main.async { [errorContinuation] in
                errorContinuation.yield(
                    "Accessibility permission not granted — open "
                    + "System Settings → Privacy & Security → "
                    + "Accessibility, enable facet, then restart")
            }
        }
    }

    /// Build the Workspace snapshot from the config's
    /// `effectiveWorkspaceList`. Each workspace starts with no
    /// windows (population is the next slice) and the matching
    /// `isActive` flag.
    private static func buildWorkspaces(
        from config: FacetConfig,
        activeIndex: Int
    ) -> [Workspace] {
        config.effectiveWorkspaceList.map { entry in
            // FacetCore's index is 0-based on the wire (matches
            // backend convention); the user-facing 1-based number
            // is `entry.index`. Translate at the seam.
            Workspace(
                index: entry.index - 1,
                name: entry.name,
                isActive: entry.index == activeIndex,
                layoutMode: "bsp",   // Phase γ revisits per-WS layout
                windows: [])
        }
    }

    public var events: AsyncStream<BackendEvent> { eventStream }
    public var errors: AsyncStream<String> { errorStream }

    // MARK: - Queries (Phase α implements; skeleton returns empty)

    public func workspaces() -> [Workspace] {
        workspaceList
    }

    public func focusedWindow() -> WindowID? {
        // Phase α: NSWorkspace.frontmostApplication → AX focused
        // window → private `_AXUIElementGetWindow` (already used in
        // `FacetAdapterRift/AXFocus.swift`, moves to a shared
        // `FacetAccessibility` module at Phase α impl time).
        nil
    }

    // MARK: - Commands (Phase β implements; skeleton no-ops)

    public func switchWorkspace(toIndex index: Int) {
        // Phase α: flip the active workspace in the self-managed
        // state, then Phase β actually parks the non-active
        // workspace's windows via the hide method from
        // config.toml [workspace] hide_method.
    }

    public func moveWindow(_ id: WindowID, toWorkspaceIndex index: Int) {
        // Phase α: update self-managed [Workspace] state.
        // Phase β: park the window if the target is non-active.
    }

    public func setLayoutMode(workspaceIndex index: Int, mode: String) {
        // Phase γ.
    }

    public func closeWindow(_ id: WindowID) {
        // Phase β: AX `kAXCloseButtonAttribute` perform action.
    }

    public func perform(_ action: WindowAction) {
        // Phase γ.
    }

    public func windowMenu(mode: String, floating: Bool) -> [WindowMenuItem] {
        // Phase γ: layout-mode-specific items. Empty stub is fine
        // for now — the right-click menu hides when items.isEmpty.
        []
    }
}
