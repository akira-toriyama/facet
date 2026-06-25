// The behavioural contract shared by the two "overview surface"
// views — the full-screen grid (`GridView`, FacetViewGrid) and the
// workspace rail (`RailView`, FacetViewRail). Both are
// `OverviewPanel`-hosted `NSView`s that the Controller drives through
// one identical wiring surface: snapshot-on-show inputs, the
// context-menu / window-move / workspace-swap callbacks, progressive
// thumbnail feeding, the neon screen-edge border, and the common
// keyboard verbs (Esc / Return / Space / Tab / `m`).
//
// This typifies what P5a/P5b already shared as *values* (`OverviewCell`
// / `OverviewDrag` / `drawMiniThumb` / `cycleSlotIndex`) one level up:
// the *behaviour* the Controller talks to. With it, `Controller+Grid`
// and `Controller+Rail` route their duplicated wiring through
// `Controller+Overview` helpers typed on `some OverviewView` instead
// of copy-pasting the two show paths.
//
// Deliberately NOT in this contract — the surfaces genuinely differ
// (the same "don't force unlike things together" judgment P5b made for
// the header band):
//   • cell geometry — grid's `cols × rows` vs the rail's active-centred
//     carousel + hero + edge docking;
//   • the pick callbacks — grid's `onPick(GridPick)` enum folds the
//     window pick in, the rail splits `onPick(Int)` / `onPickWindow`;
//   • directional nav — `kbMoveSelection(dx:dy:)` (2-D) vs `(dx:)`
//     (1-D, axis from the docked edge);
//   • the rail's scroll-wheel rotation (`scrollRotate`);
//   • per-view animation — grid FLIP reorder vs rail carousel slide.

import AppKit
import FacetCore

@MainActor
public protocol OverviewView: NSView {

    // MARK: Snapshot-on-show inputs (set once at build time)

    /// Per-surface palette box (`[grid].theme` / `[rail].theme`), also
    /// shared with the view's `BorderFX`.
    var paletteBox: PaletteBox! { get set }
    /// The workspaces captured at show time — the surface does not
    /// track live backend events while it is up. ALWAYS the UNFILTERED set
    /// (even under an active lens): the landing gate / cell count / swap
    /// source it, so it must mirror the live backend, not the lens view.
    var workspaces: [Workspace] { get set }
    /// Index of the active workspace at show time.
    var activeIndex: Int? { get set }
    /// The projected section list (EX-2): the SAME ordered `[ProjectedSection]`
    /// the tree renders (`type=workspace` + `type=lens`). Empty ⇒ the section
    /// model is off here ⇒ the surface falls back to iterating `workspaces`
    /// (byte-identical degrade). `workspaces` stays the unfiltered snapshot.
    var sections: [ProjectedSection] { get set }
    /// The active lens's stable section id (`ProjectedSection.id`, EX-2 / §A),
    /// or nil when a workspace is the active section. Gates the single-highlight:
    /// when non-nil, workspace cells suppress their active accent and only the
    /// lens cell whose `id` matches lights. Keyed on the id, not the display
    /// label, so a non-unique / empty label can't light the wrong cell.
    var activeLensID: String? { get set }
    /// Display frame the windows were measured against; mini-thumb
    /// rects scale from it.
    var screenFrame: CGRect { get set }
    /// Backend for the shared context menu (③).
    var backend: (any WindowBackend)? { get set }

    // MARK: Shared callbacks

    /// Click outside any cell, or Esc — the Controller owns the
    /// hide / restore sequence.
    var onDismiss: (() -> Void)? { get set }
    /// Runs the non-close window-ops a context-menu pick chose (③).
    var onRunWindowOps: ((_ ops: [WindowAction],
                          _ window: Window, _ ws: Int) -> Void)? { get set }
    /// Drag a window thumbnail onto another workspace cell → move it
    /// there. The Controller owns the backend round-trip + re-query.
    var onMoveWindow: ((_ src: Int, _ dst: Int,
                        _ pid: Int, _ id: WindowID) -> Void)? { get set }
    /// Drag a cell header onto another cell → swap the two workspaces'
    /// contents (the WM indices stay put; only the windows trade).
    var onSwap: ((_ srcWS: Int, _ dstWS: Int,
                  _ srcIDs: [WindowID], _ dstIDs: [WindowID]) -> Void)? { get set }
    /// Drag a cell header to a new slot → REORDER the section list (display-
    /// only, session-only). `boundary` is the insertion index in the projected
    /// section order. No window moves, no config write. (Mouse path; the
    /// keyboard header-lift still swaps for now.)
    var onReorder: ((_ sectionID: String, _ toBoundary: Int) -> Void)? { get set }

    // MARK: Lifecycle / feeding

    /// Recompute every workspace cell from `workspaces`.
    func layoutCells()
    /// Feed a captured thumbnail in as it lands (progressive paint).
    func setThumbnail(_ image: NSImage, for id: WindowID)
    /// Release every cached thumbnail (on hide).
    func clearThumbnails()

    // MARK: Neon border (shared `BorderFX`)

    func applyBorder(effectName: String, glow: Bool, width: CGFloat,
                     cycleSeconds: CGFloat, cycleColors: Bool,
                     minWidth: CGFloat?, maxWidth: CGFloat?)
    func flashBorder()
    func stopBorder()

    // MARK: Common keyboard verbs (the view-specific arrow nav stays out)

    func kbEscape()
    func kbCommit()
    func kbSpaceLift()
    func kbCycleWindow(forward: Bool)
    func kbContextMenu()
}
