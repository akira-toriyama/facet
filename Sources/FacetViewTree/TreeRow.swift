// Row types shared between `SidebarView` and the keyboard-nav free
// functions in `KbNav.swift`. Module-scoped (not nested inside
// `SidebarView`) so the kb-nav helpers can take `[TreeRow]` without
// pulling SidebarView in — keeps them pure-logic + unit-testable.

import AppKit
import FacetCore

/// A row's kind. `group` is the rendered-group ORDINAL (0-based, display
/// order) — it names the row's SECTION, which is how a click resolves back to
/// `lastSections[group]`. In the by-workspace degrade
/// `group == workspaceIndex == ws.index`, so every comparison (DnD bands,
/// kbNav) holds byte-identically.
///
/// `workspaceIndex` is the BACKEND ACTION TARGET, kept SEPARATE from `group`:
/// the real workspace a click acts on (switch / focus / move). For a window
/// row it is the window's REAL workspace even inside an isolate desktop's
/// synthesized section; for a `workspace`-section header it is the source
/// workspace; for an isolate desktop's synthesized header (matched / holding)
/// it is `nil` — there is no workspace to switch to, so a click focuses that
/// section's first window instead (`focusFirstWindow(inSectionID:)`).
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
/// `(group, WindowID)` (the group names the section it was selected in);
/// a header by its `group` ordinal.
enum TreeKbSel: Equatable {
    case win(group: Int, WindowID)
    case hdr(group: Int)
}
