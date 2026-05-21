// Row types shared between `SidebarView` and the keyboard-nav free
// functions in `KbNav.swift`. Extracted to module scope (vs nested
// in SidebarView like in ws-tabs) so the kb-nav helpers can take
// `[TreeRow]` without needing SidebarView in scope — that's what
// keeps them pure-logic and unit-testable.

import AppKit
import FacetCore

enum TreeRowKind {
    case handle
    case header(workspaceIndex: Int)
    case window(workspaceIndex: Int,
                pid: Int,
                windowID: WindowID,
                title: String)
    case search
}

struct TreeRow {
    let rect: NSRect
    let kind: TreeRowKind
}

/// Keyboard selection by *logical identity*, not array position —
/// the selection survives the 2 s refresh / rift events that
/// rebuild `rows` from scratch. A window stays selected by its
/// `WindowID`; an empty workspace by its index.
enum TreeKbSel: Equatable {
    case win(WindowID)
    case hdr(workspaceIndex: Int)
}
