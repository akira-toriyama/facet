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
    public let name = "rift"

    public let layoutModes = [
        "master_stack", "traditional", "bsp", "stack", "scrolling",
    ]

    private let eventSource: EventSource

    private let errorStream: AsyncStream<String>
    private let errorContinuation: AsyncStream<String>.Continuation

    public init() {
        self.eventSource = EventSource()
        var cont: AsyncStream<String>.Continuation!
        self.errorStream = AsyncStream { c in cont = c }
        self.errorContinuation = cont
    }

    public var events: AsyncStream<BackendEvent> { eventSource.stream }
    public var errors: AsyncStream<String> { errorStream }

    /// Push a user-actionable failure into the errors stream. Every
    /// rift-cli failure routes through here so `facet status` users
    /// see a consistent "is rift running?" hint.
    private func pushError(_ command: String) {
        errorContinuation.yield(
            "rift-cli \(command) failed — is rift running? "
            + "(`rift service start` or activate with Alt+Z)")
    }

    /// Run a rift-cli command and push an error if it fails. Used by
    /// every void-returning execute method below so the noise stays
    /// in one place.
    @discardableResult
    private func runOrReport(_ args: [String], label: String) -> Data? {
        let data = RiftCLI.run(args)
        if data == nil { pushError(label) }
        return data
    }

    // MARK: - Queries

    public func workspaces() -> [Workspace] {
        guard
            let data = RiftCLI.run(["query", "workspaces"]),
            let raw = try? JSONDecoder().decode([RFWorkspace].self, from: data)
        else {
            pushError("query workspaces")
            return []
        }
        return raw
            .sorted { $0.index < $1.index }
            .map(RiftMapper.workspace(from:))
    }

    public func focusedWindow() -> WindowID? {
        guard let data = RiftCLI.run(["query", "windows"]) else {
            pushError("query windows")
            return nil
        }
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
        runOrReport(
            ["execute", "workspace", "switch", String(index)],
            label: "workspace switch \(index)")
    }

    public func moveWindow(_ id: WindowID, toWorkspaceIndex index: Int) {
        runOrReport(
            ["execute", "workspace", "move-window",
             String(index), String(id.serverID)],
            label: "workspace move-window \(index)")
    }

    public func setLayoutMode(workspaceIndex index: Int, mode: String) {
        runOrReport(
            ["execute", "workspace", "set-layout",
             "--workspace-id", String(index), mode],
            label: "workspace set-layout \(mode)")
    }

    public func closeWindow(_ id: WindowID) {
        runOrReport(
            ["execute", "window", "close",
             "--window-id", String(id.serverID)],
            label: "window close")
    }

    public func perform(_ action: WindowAction) {
        let (args, label): ([String], String)
        switch action {
        case .toggleFloat:
            (args, label) = (["execute", "window", "toggle-float"],
                             "window toggle-float")
        case .toggleFullscreen:
            (args, label) = (["execute", "window", "toggle-fullscreen"],
                             "window toggle-fullscreen")
        case .promoteToMaster:
            (args, label) = (["execute", "layout", "promote-to-master"],
                             "layout promote-to-master")
        case .swapMasterStack:
            (args, label) = (["execute", "layout", "swap-master-stack"],
                             "layout swap-master-stack")
        case .toggleStack:
            (args, label) = (["execute", "layout", "toggle-stack"],
                             "layout toggle-stack")
        case .toggleOrientation:
            (args, label) = (["execute", "layout", "toggle-orientation"],
                             "layout toggle-orientation")
        case .centerColumn:
            (args, label) = (["execute", "layout", "center-selection"],
                             "layout center-selection")
        case .snapStrip:
            (args, label) = (["execute", "layout", "snap-strip"],
                             "layout snap-strip")
        }
        runOrReport(args, label: label)
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
