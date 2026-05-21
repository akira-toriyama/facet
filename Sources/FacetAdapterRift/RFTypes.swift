// Adapter-private mirror of rift-cli's JSON output. These never
// escape the module — `RiftMapper` converts them to the
// backend-neutral `Workspace` / `Window` types declared in FacetCore.
// Keeping the snake_case wire format on the identifiers makes
// hand-correlating with rift output trivial.

import Foundation
import CoreGraphics

struct RFWinId: Decodable, Sendable {
    let idx: Int
    let pid: Int
}

struct RFPoint: Decodable, Sendable {
    let x: Double
    let y: Double
}

struct RFSize: Decodable, Sendable {
    let width: Double
    let height: Double
}

struct RFRect: Decodable, Sendable {
    let origin: RFPoint
    let size: RFSize

    var cg: CGRect {
        CGRect(x: origin.x, y: origin.y,
               width: size.width, height: size.height)
    }
}

struct RFWindow: Decodable, Sendable {
    let app_name: String
    let id: RFWinId
    let is_focused: Bool
    let is_floating: Bool?
    let title: String
    let window_server_id: Int
    // rift's *logical* on-screen frame. For an inactive workspace
    // the actual (SCWindow) frame is parked far off-screen; this is
    // where the window would sit after a switch — preview placement
    // anchors here.
    let frame: RFRect?
}

struct RFWorkspace: Decodable, Sendable {
    let index: Int
    let is_active: Bool
    let name: String
    let layout_mode: String
    let windows: [RFWindow]
}
