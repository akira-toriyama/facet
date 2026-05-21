// `WindowBackend` conformance against rift-cli. Every rift command
// string lives in this file — the rest of the app talks to
// `WindowBackend` and never sees rift again.

import Foundation
import FacetCore

// ``@unchecked Sendable`` is safe here: every stored property is
// ``let`` (immutable post-init). The only mutable state is
// encapsulated inside ``EventSource``, which guards it with its
// own serial dispatch queue (see EventSource.swift).
public final class RiftAdapter: WindowBackend, @unchecked Sendable {
    public let layoutModes = [
        "master_stack", "traditional", "bsp", "stack", "scrolling",
    ]

    private let eventSource: EventSource

    public init() {
        self.eventSource = EventSource()
    }

    public var events: AsyncStream<BackendEvent> { eventSource.stream }

    // MARK: - Queries

    public func workspaces() -> [Workspace] {
        guard
            let data = RiftCLI.run(["query", "workspaces"]),
            let raw = try? JSONDecoder().decode([RFWorkspace].self, from: data)
        else { return [] }
        return raw
            .sorted { $0.index < $1.index }
            .map(RiftMapper.workspace(from:))
    }

    public func focusedWindow() -> WindowID? {
        guard let data = RiftCLI.run(["query", "windows"]) else { return nil }
        // rift-cli's `query windows` shape has shifted across releases —
        // sometimes a flat [RFWindow], sometimes [RFWorkspace]. Accept
        // either; this is what ws-tabs did, kept verbatim.
        if let wins = try? JSONDecoder().decode([RFWindow].self, from: data) {
            return wins.first(where: \.is_focused)
                .map { WindowID(serverID: $0.window_server_id) }
        }
        if let wss = try? JSONDecoder().decode([RFWorkspace].self, from: data) {
            return wss.flatMap(\.windows)
                .first(where: \.is_focused)
                .map { WindowID(serverID: $0.window_server_id) }
        }
        return nil
    }

    // MARK: - Commands

    public func switchWorkspace(toIndex index: Int) {
        RiftCLI.run(["execute", "workspace", "switch", String(index)])
    }

    public func moveWindow(_ id: WindowID, toWorkspaceIndex index: Int) {
        RiftCLI.run([
            "execute", "workspace", "move-window",
            String(index), String(id.serverID),
        ])
    }

    public func setLayoutMode(workspaceIndex index: Int, mode: String) {
        RiftCLI.run([
            "execute", "workspace", "set-layout",
            "--workspace-id", String(index), mode,
        ])
    }

    public func closeWindow(_ id: WindowID) {
        RiftCLI.run([
            "execute", "window", "close",
            "--window-id", String(id.serverID),
        ])
    }

    public func perform(_ action: WindowAction) {
        switch action {
        case .toggleFloat:
            RiftCLI.run(["execute", "window", "toggle-float"])
        case .toggleFullscreen:
            RiftCLI.run(["execute", "window", "toggle-fullscreen"])
        case .promoteToMaster:
            RiftCLI.run(["execute", "layout", "promote-to-master"])
        case .swapMasterStack:
            RiftCLI.run(["execute", "layout", "swap-master-stack"])
        case .toggleStack:
            RiftCLI.run(["execute", "layout", "toggle-stack"])
        case .toggleOrientation:
            RiftCLI.run(["execute", "layout", "toggle-orientation"])
        case .centerColumn:
            RiftCLI.run(["execute", "layout", "center-selection"])
        case .snapStrip:
            RiftCLI.run(["execute", "layout", "snap-strip"])
        }
    }

    // MARK: - Menu

    public func windowMenu(mode: String, floating: Bool) -> [WindowMenuItem] {
        var items: [WindowMenuItem] = []
        // Floating windows aren't in the tiling tree → unfloat first
        // so layout-mode actions have something to operate on.
        let pre: [WindowAction] = floating ? [.toggleFloat] : []
        switch mode {
        case "master_stack":
            items.append(.init("Promote to master", pre + [.promoteToMaster]))
            items.append(.init("Swap master / stack", pre + [.swapMasterStack]))
        case "traditional", "bsp":
            items.append(.init("Toggle stack", [.toggleStack]))
            items.append(.init("Toggle orientation", [.toggleOrientation]))
        case "stack":
            items.append(.init("Toggle orientation", [.toggleOrientation]))
        case "scrolling":
            items.append(.init("Center column", [.centerColumn]))
            items.append(.init("Snap strip", [.snapStrip]))
        default:
            break
        }
        items.append(.init(floating ? "Unfloat" : "Float", [.toggleFloat]))
        items.append(.init("Toggle fullscreen", [.toggleFullscreen]))
        items.append(.init("Close window", [], close: true))
        return items
    }
}
