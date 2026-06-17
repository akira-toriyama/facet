// Row types shared between `SidebarView` and the keyboard-nav free
// functions in `KbNav.swift`. Module-scoped (not nested inside
// `SidebarView`) so the kb-nav helpers can take `[TreeRow]` without
// pulling SidebarView in — keeps them pure-logic + unit-testable.

import AppKit
import FacetCore

/// A row's kind. `group` is the rendered-group ORDINAL (0-based, display
/// order) — the BLOCKER fix for the section/lens model (PR5): under
/// multi-match a window appears in several sections, so a `WindowID` alone
/// no longer identifies a row; `(group, windowID)` does. In the by-workspace
/// degrade `group == workspaceIndex == ws.index`, so every existing
/// comparison (DnD bands, kbNav) holds byte-identically.
///
/// `workspaceIndex` is the BACKEND ACTION TARGET, kept SEPARATE from `group`:
/// the real workspace a click acts on (switch / focus / move). For a window
/// row it is the window's REAL workspace even inside a lens section; for a
/// `workspace`-section header it is the source workspace; for a `lens`-section
/// header it is `nil` (a lens has no workspace to switch to — PR6 activates
/// it instead).
enum TreeRowKind {
    case header(group: Int, workspaceIndex: Int?)
    case window(group: Int,
                workspaceIndex: Int,
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
/// `(group, WindowID)` (the group disambiguates the same window shown in
/// several sections under multi-match); a header by its `group` ordinal.
enum TreeKbSel: Equatable {
    case win(group: Int, WindowID)
    case hdr(group: Int)
}
