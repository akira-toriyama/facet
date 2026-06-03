// Row types shared between `SidebarView` and the keyboard-nav free
// functions in `KbNav.swift`. Module-scoped (not nested inside
// `SidebarView`) so the kb-nav helpers can take `[TreeRow]` without
// pulling SidebarView in — keeps them pure-logic + unit-testable.

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
/// the selection survives the 2 s refresh / backend events that
/// rebuild `rows` from scratch. A window stays selected by its
/// `WindowID`; an empty workspace by its index.
enum TreeKbSel: Equatable {
    case win(WindowID)
    case hdr(workspaceIndex: Int)
}
