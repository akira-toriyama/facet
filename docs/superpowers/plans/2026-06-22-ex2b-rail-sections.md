# EX-2b — Rail Section Cells + Hero + Unified Highlight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. This is the **detailed re-plan of the EX-2b row** deferred at the end of [2026-06-21-ex2-overview-sections.md](2026-06-21-ex2-overview-sections.md) (Decision 2: "rail is all-or-nothing → full EX-2b, re-planned at its start"), refreshed against the **EX-2a foundation** (main `445f162`, PR #316). The parent plan's EX-0→EX-4 phase split is unchanged; this doc expands EX-2b.

**Goal:** Make the **rail** (full-screen Mission-Control-style carousel overlay) render the **same ordered `[ProjectedSection]` list as the tree and grid** — workspace cells **and** `type="lens"` cells in the carousel strip — so all three views show **exactly one lit highlight**; the **hero** (centre cell) renders the selected/centred section, and **when a lens is the centred section the hero renders its cross-workspace union** (トミー decision 2026-06-22). Route every cell/window/header pick through the existing `activateSection` throughline (mirror the grid's `onPick`), never `bk.switchWorkspace` directly. Closing the "declared gap" EX-2a left (the rail still lights its active-workspace cell under an active lens) completes the **3-view unified highlight** deliverable.

**Architecture:** EX-1 gave the tree single-highlight (one `headerActive` XOR gate) + a backend `activateSection(_:autoFocus:)` throughline. EX-2a carried both to the **grid**: it baked the XOR into `OverviewCell.isActive` at cell-build time (so the accent draw needs **zero change**) and routed clicks through `Controller.activateSection` via a `GridPick` enum with a `.lens` case. EX-2b carries the **same two things** to the rail, plus the rail-specific carousel mechanics:

1. **Iterate `sections` (not `workspaces`)** in `layoutCells` to build the carousel cells — a rail-local `overviewCellSources()` bridge mirroring the grid's, with the **single-highlight XOR baked into `isActive`** and a degrade fallback to `workspaces` (byte-identical when no section model).
2. **Re-key the browse cursor `selectedWS: Int?` → `selectedSectionID: String?`** (lens cells all share `wsIndex == −1`, an Int cursor cannot address them). Every read/write of `selectedWS` migrates to the stable `ProjectedSection.id`. This is the rail analog of the grid's `kbSelectedWS → kbSelectedID` re-key — but **load-bearing for the carousel geometry** (the rail centres the strip on the cursor), so it lands as **one coherent build-green commit** with everything that references it (the grid could split because its `kbSelectedWS` was decoupled from layout; the rail's cannot).
3. **Hero = the centred section.** When the centred section is a lens, the hero renders the lens's union windows (`ProjectedSection.windows`); when a workspace, the workspace's windows as today. The hero's `isActive` is the baked XOR.
4. **Pick routing through `activateSection`** via a new `RailPick` enum (`.workspace` / `.lens` / `.window(homeWorkspaceIndex:)`), replacing the rail's two bespoke closures (`onPick(Int)` + `onPickWindow`). Window picks resolve the window's true home workspace via a `windowHomeWS` map (the MUST-FIX #1 analog), so a window thumb inside a lens cell focuses + switches to its home WS.
5. **Lens cells are browsable but never drag/swap targets or sources** (mouse + keyboard): no move-onto, no header-swap, no lift, no layout picker, no grip dots — the same guards the grid established.
6. **Persistent-rail re-light.** The rail stays open across reconciles (unlike the snapshot-on-show grid). The Controller's `apply()` rail feed already re-seeds `rv.sections`/`rv.activeLens` + relayouts every reconcile; its **carousel re-centre** (`rv.selectedWS == oldActive` → follow the new active) generalises to `selectedSectionID == oldActiveSectionID` via a pure FacetCore `activeSectionID(...)` helper, so an external lens activate/clear re-lights + re-centres without a fresh show.

**Tech Stack:** Swift 6, macOS 13+, SwiftPM. 3-layer spine: `FacetCore` (pure) / `FacetAdapterNative` (AX + catalog, `cliQueue`-confined) / `FacetView*` + `FacetApp` (GUI/Controller). Tests are XCTest, **CI-only** (local gate is `swift build`). `FacetViewRail` (RailView/RailHeader/RailDrag) and the Controller have **no XCTest harness** — they are build-gated + host-verified. The only unit-testable EX-2b piece is the pure `activeSectionID` helper (FacetCore).

## Global Constraints

- **Layer spine is non-negotiable.** `FacetCore` pure (CoreGraphics OK, no AppKit / no AX / no backend types). `ProjectedSection`/`OverviewCell`/`ActiveSection`/`SectionType`/`activeSectionID(...)` are pure FacetCore. `RailPick` is a `FacetViewRail` `Sendable` enum (like `GridPick` in `FacetViewGrid`). Views talk to `WindowBackend` + the Controller-supplied closures, never a concrete adapter. ([[facet-architecture-decisions]])
- **Catalog is the single state authority.** active-section / park sets live in `WorkspaceCatalog` (mutated only on `cliQueue`). Views read a snapshot. `OverviewCell.isActive` is a *render mirror* computed from the snapshot's `activeLens` + `Workspace.isActive`, never an independent source of truth.
- **`workspaces` stays the UNFILTERED snapshot.** `RailView.workspaces` remains the full set: it is the authority for `windowHomeWS` (window → home WS), the swap source (`commitContentSwap` reads `workspaces.first { $0.index == dstCell.wsIndex }`), and the drag landing gate (`OverviewPendingDrop.landed(in: workspaces)`). EX-2b **adds** `sections` consumption **alongside** it.
- **`ActiveSection.workspace(Int)` is 1-based; cell/workspace indices are 0-based.** `OverviewCell.wsIndex == Workspace.index` (0-based). Routing a workspace pick → `activateSection(.workspace(wsIndex + 1))`; a window pick → `activateSection(.workspace(home + 1))` guarded `home >= 0`. **This +1 is the off-by-one that bit EX-1 (M1) and was re-flagged in EX-2a — get it right.**
- **Tests compile in CI only.** The `activeSectionID` FacetCore test needs no `cliQueue` wrap (pure). Local gate is `swift build`. ([[feedback-swift-tests-only-compile-in-ci]])
- **Loud on typo, silent on success.** Routing through `controller.activateSection` reuses the EX-1 validation (unknown lens label → operational error; range-checked workspace index). EX-2b adds no new error surface. ([[control-is-cli-first]])
- **No push/merge without an explicit OK from トミー.** Commit locally on `feat/ex2b-rail-sections`; squash-merge only on go. View changes are host-verified by トミー (synthetic input NG — [[claude-driven-testing-protocol]], [[feedback-no-input-injection-while-active]]; a time-boxed autonomous host-verify with explicit consent is allowed, per the EX-2a precedent + [[feedback-announce-before-automation]]). ([[pr-conventions]], [[grid-view-work-style]])
- **Patch by SYMBOL, not line number.** All line numbers below are *as of main `445f162`* (verified by direct source read 2026-06-22) and must be re-located by symbol before editing.

---

## EX-2a foundation recap (what EX-2b builds on — already shipped)

Verified in source at main `445f162` + via the EX-2b codemap (`wf_fc77532c-8d2`, 6 readers):

- **`OverviewCell`** ([OverviewModels.swift](../../../Sources/FacetCore/OverviewModels.swift)) carries `sectionType: SectionType` (default `.workspace`), `sectionID: String` (default `""`), and `var isLens: Bool { sectionType == .lens }`. Defaulted, so existing call sites compile. The rail's cell builds currently pass neither (defaults).
- **`OverviewView` protocol** ([OverviewView.swift](../../../Sources/FacetView/OverviewView.swift)) has `sections: [ProjectedSection]` + `activeLens: String?`. **`RailView` already STORES both** ([RailView.swift](../../../Sources/FacetViewRail/RailView.swift), `public var sections` / `public var activeLens`) but **does not consume them** — that is this phase.
- **Controller `apply()`** ([Controller.swift](../../../Sources/FacetApp/Controller.swift)) hoists `FilterProjection.project` once (~890), stashes `lastSections`/`lastActiveLens`, and **already feeds the rail** symmetrically (`rv.sections = lastSections; rv.activeLens = lastActiveLens` at ~920) + relayouts every reconcile. The rail feed also has the **carousel re-centre** (`if rv.selectedWS == oldActive, let na = newActive { rv.selectedWS = na }`, ~926) — EX-2b generalises this.
- **`GridPick`** ([GridPick.swift](../../../Sources/FacetViewGrid/GridPick.swift)): `.workspace(workspaceIndex: Int)` / `.lens(label: String)` / `.window(homeWorkspaceIndex: Int, pid: Int, windowID: WindowID)` — the shape `RailPick` mirrors.
- **Grid `overviewCellSources()`** ([GridView.swift](../../../Sources/FacetViewGrid/GridView.swift)) is the proven bridge (degrade to workspaces when `sections.isEmpty`; XOR `isActive = isLens ? (activeLens != nil && sec.label == activeLens) : (activeLens == nil && srcWS?.isActive == true)`). It is `private` to `FacetViewGrid` → the rail builds its **own** identical bridge.
- **Grid `Controller+Grid` `onPick`** routes `.workspace(ws)` → `activateSection(.workspace(ws+1), autoFocus: true)`, `.lens(label)` → `activateSection(.lens(label), autoFocus: true)`, `.window(home,…)` → guard `home >= 0` then `activateSection(.workspace(home+1), autoFocus: false)` + `cliQueue` `Focus.assert`. `Controller+Rail` `onPick` must adopt this exactly (it currently calls `bk.switchWorkspace` directly).
- **Pure rail geometry is index-agnostic.** `railCarouselOffsets(count:selectedPos:)` / `railBands(...)` / `railScaledPads(...)` ([RailGeometry.swift](../../../Sources/FacetCore/RailGeometry.swift)) take a count + a 0-based **array position**, not workspace identity. `Tunables.swift` constants are cell-kind-agnostic. **EX-2b needs ZERO change to FacetCore RailGeometry / Tunables** (codemap `rail-geometry-pure` reader: empty `ex2bChanges`).

---

## Design decisions locked (this re-plan)

Implementation-shape calls delegated to Claude by the design canon ([[facet-tag-unification-design]]: "tree の見た目・実装フェーズの刻み方は全てクロード委任"); the one flagged **visual** call was put to トミー and answered.

1. **トミー decision (2026-06-22): when a lens is the active/centred section, the lens cell becomes the HERO rendering its union.** ("lens を hero 化 (推奨)".) Preserves the carousel invariant "centre hero = the active section". The hero reads `ProjectedSection.windows` (the cross-workspace union) for a lens, the workspace's windows otherwise.
2. **The carousel iterates the FULL `[ProjectedSection]` list (workspace + lens cells); lens cells appear in the strip and are browsable.** This is the only model consistent with both Decision 1 and the parent plan's EX-2 deliverable ("3-view＝同一 section リスト"). Browse arrows / scroll rotate through **all** sections (lenses included — **no skip**); landing the cursor on a lens makes it the hero; Return/click activates it. (The codemap's `rail-click-routing` reader flagged uncertainty here — this decision resolves it: lens cells ARE carousel cells, exactly as they are grid cells.)
3. **`selectedWS: Int?` → `selectedSectionID: String?`.** Keyed on `ProjectedSection.id` (`"ws:<i>"` / `"section:<declOrder>:<label>"`), the rail analog of the grid's `kbSelectedID`. The `wsIndex == −1` lens sentinel STAYS for cell identity / drag-target rejection; only the browse cursor stops keying on `wsIndex`.
4. **Single-highlight is baked into `OverviewCell.isActive` at build time — the active-accent draw path is unchanged.** `drawCell`'s hero accent (`c.isActive ? pal.primary : pal.secondary`) and strip-active accent (`else if c.isActive`) already read `cell.isActive` only. The **browse-target** accent (`drag == nil && selectedWS == c.wsIndex` → secondary), the **hover** accent (`hoverWS == c.wsIndex`), the **window-ring** gate (`c.isHero || c.wsIndex == selectedWS`), and `RailHeader`'s `kbWholeWS`/hover re-key from `wsIndex` → `sectionID` (lens cells collide on `−1`).
5. **Pick routing reuses one `RailPick` enum** (mirror `GridPick`), replacing `onPick(Int)` + `onPickWindow`. The Controller closure (which holds `[weak self]`) routes to `self?.activateSection`. No new view→controller protocol; the asymmetry-with-grid is removed.
6. **Lens cells are not DnD targets or sources.** A lens has no `sourceWorkspaceIndex`. Guard every move/swap path (mouse `dropTargetWS`, keyboard `syncRailDragToSelection`, `kbLiftWorkspace`, the hero-window lift `kbLiftWindow` when the hero is a lens, the `mouseDragged` promotion). A lens header is a **click target, not a swap handle** → fire `.lens` on press, never arm a swap-drag (no grip dots). A window thumb *inside* a lens cell, clicked, still focuses that window (switches to its home workspace first, via `windowHomeWS`).
7. **`commitSwitch` (hero-zoom) keys on the centred section, not a workspace index.** Re-signature `commitSwitch(target ws: Int, …)` → `commitSwitch(targetSectionID: String, …)`; the zoom plays iff `targetSectionID == selectedSectionID` (the centred hero) — works for a lens activation (zooms the lens union hero) exactly as for a workspace switch.
8. **Persistent-rail re-centre generalises via a pure helper.** `activeSectionID(activeLens:activeIndex:sections:) -> String?` (FacetCore, testable) returns the lit section's id; the Controller's rail feed re-centres `selectedSectionID` on the new active section iff the cursor was on the old one (faithful generalisation of the existing `selectedWS == oldActive` guard).
9. **Degrade path preserved byte-identically.** When `sections` is empty (section model off here), `overviewCellSources()` returns one source per workspace with `sectionID = "ws:<i>"` and `isActive = activeLens == nil && ws.isActive` — the carousel/hero/cursor all work on those synthetic ids, rendering exactly as pre-EX-2b.

### Deferred (declared, not dropped — 未達成を暗黙にしない)

- **Lens-cell window mini-layout polish (carries from EX-2a).** A lens cell / lens hero lays out its member windows by their real `Window.frame` scaled into the cell. When the lens is **active** they are union-tiled (looks right); when **inactive** (browsed-but-not-activated) they sit at their home frames and may overlap. Acceptable cosmetic for EX-2b (the cell/hero is mainly a click target; activating union-tiles). Refine in brushup if トミー dislikes it during dogfood ([[facet-dogfood-adoption-test]]).
- **A window in a lens cell/hero is not move-liftable** (mouse drag or keyboard Space). Matches the grid's `kbLift` `!cell.isLens` guard. To move a window out of a lens view, activate a workspace first. (Decision 6.)
- **`updateConfig` auto-clear of a now-undefined active lens** — pre-existing #313 MINOR BACKLOG carried through EX-1/EX-2a; still backlog.

---

## File structure

| File | Responsibility | Task |
|---|---|---|
| `Sources/FacetCore/ActiveSection.swift` | NEW pure `activeSectionID(activeLens:activeIndex:sections:) -> String?` helper. | EX-2b.1 |
| `Tests/FacetCoreTests/ActiveSectionTests.swift` (NEW or extend) | `activeSectionID` cases: lens active, workspace active, degrade (empty sections), no-match. | EX-2b.1 |
| `Sources/FacetViewRail/RailPick.swift` | NEW `public enum RailPick: Sendable` (`.workspace`/`.lens`/`.window`), mirroring `GridPick`. | EX-2b.2 |
| `Sources/FacetViewRail/RailView.swift` | `overviewCellSources()`+`CellSource`; `scaledWins([Window])`; `windowHomeWS`+`sectionOrder` state; `selectedWS`→`selectedSectionID`; `layoutCells` iterates sources (degrade fallback) + hero from selected source (lens union) + baked single-highlight; `commitSwitch(targetSectionID:)`; `draw`/hover re-key; mouse + kb pick routing through `RailPick` + lens guards + `windowHomeWS`. | EX-2b.2 |
| `Sources/FacetViewRail/RailHeader.swift` | `kbWholeWS`/hover re-key to `sectionID`; suppress grip dots + use bare label for lens cells. | EX-2b.2 |
| `Sources/FacetApp/Controller+Rail.swift` | `rv.onPick` (single `RailPick` closure) routes through `activateSection` (mirror grid); drop the direct `bk.switchWorkspace` + the `onPickWindow` closure + the `rv.selectedWS = rv.activeIndex` seed. | EX-2b.2 |
| `Sources/FacetApp/Controller.swift` | rail feed re-centre: `selectedWS == oldActive` → `selectedSectionID == oldActiveSectionID` via `activeSectionID(...)`. | EX-2b.2 |
| `config.toml`, `docs/glossary.md`, `docs/architecture.md`, `README.md`, `README.ja.md` | doc 3-view parity complete (rail now renders lens cells + hero union); close the EX-2a "declared gap". | EX-2b.3 |

Execution: one branch `feat/ex2b-rail-sections`. **EX-2b.1** is a standalone additive build-green commit (pure helper + test). **EX-2b.2** is one coherent build-green commit (the rename is load-bearing for layout, so it cannot be split while staying compilable — see Architecture #2). **EX-2b.3** is docs. Adversarial review after EX-2b.2 (the meat). **ONE host-verify after EX-2b.3** (トミー operates; synthetic input only with fresh consent).

---

## Task EX-2b.1: pure `activeSectionID` helper (FacetCore, additive, testable)

**Files:**
- Modify: `Sources/FacetCore/ActiveSection.swift` (add the free function)
- Test: `Tests/FacetCoreTests/ActiveSectionTests.swift` (new or extend)

**Interfaces:**
- Produces: `public func activeSectionID(activeLens: String?, activeIndex: Int?, sections: [ProjectedSection]) -> String?` — the stable id of the lit section, EXACTLY matching `overviewCellSources`'s XOR (lens lit ⟺ its label == activeLens; else the workspace section whose source index == activeIndex; degrade ⟺ `"ws:<activeIndex>"`).
- Consumes: `ProjectedSection` (`id`/`label`/`sourceWorkspaceIndex`/`sectionType`), `SectionType`.

- [ ] **Step 1: Write the failing FacetCore test**

```swift
// Tests/FacetCoreTests/ActiveSectionTests.swift  (extend if it exists)
import XCTest
@testable import FacetCore

final class ActiveSectionIDTests: XCTestCase {
    private func ws(_ i: Int) -> ProjectedSection {
        ProjectedSection(id: "ws:\(i)", label: "W\(i)", windows: [],
                         sourceWorkspaceIndex: i, sectionType: .workspace)
    }
    private func lens(_ order: Int, _ label: String) -> ProjectedSection {
        ProjectedSection(id: "section:\(order):\(label)", label: label, windows: [],
                         sourceWorkspaceIndex: nil, sectionType: .lens)
    }
    func testLensActiveWins() {
        let secs = [ws(0), ws(1), lens(2, "Web")]
        XCTAssertEqual(activeSectionID(activeLens: "Web", activeIndex: 0, sections: secs),
                       "section:2:Web")
    }
    func testWorkspaceActiveWhenNoLens() {
        let secs = [ws(0), ws(1), lens(2, "Web")]
        XCTAssertEqual(activeSectionID(activeLens: nil, activeIndex: 1, sections: secs), "ws:1")
    }
    func testDegradeEmptySections() {
        XCTAssertEqual(activeSectionID(activeLens: nil, activeIndex: 2, sections: []), "ws:2")
        XCTAssertNil(activeSectionID(activeLens: nil, activeIndex: nil, sections: []))
    }
    func testUnknownLensFallsBackNil() {
        // active lens label not present in sections → no lit section id
        XCTAssertNil(activeSectionID(activeLens: "Ghost", activeIndex: 0, sections: [lens(1, "Web")]))
    }
}
```

> Verify `ProjectedSection`'s member initializer is accessible from the test (it is `public` per the codemap). If the real init has more/renamed params, match them — re-locate by symbol.

- [ ] **Step 2: Run to verify it fails** — `swift build` then (CI) `swift test --filter ActiveSectionIDTests`. Expected: compile FAIL (`activeSectionID` undefined). Locally `swift build` fails to compile the test.

- [ ] **Step 3: Add the helper**

In `Sources/FacetCore/ActiveSection.swift` (alongside the `ActiveSection` enum):

```swift
/// EX-2b: the stable `ProjectedSection.id` of the **lit** section — the
/// single-highlight authority shared by the overview surfaces. Matches
/// `overviewCellSources`'s XOR exactly:
///   • an active lens lights its lens cell (id `"section:<order>:<label>"`);
///   • otherwise the workspace section whose source index is `activeIndex`;
///   • degrade (no section model ⇒ empty `sections`) ⇒ `"ws:<activeIndex>"`.
/// `nil` when nothing is lit (no active index, or an active lens with no
/// matching section). Pure — used by the Controller's persistent-rail
/// re-centre and (conceptually) the seed of the rail browse cursor.
public func activeSectionID(activeLens: String?, activeIndex: Int?,
                            sections: [ProjectedSection]) -> String? {
    if let lens = activeLens {
        return sections.first { $0.sectionType == .lens && $0.label == lens }?.id
    }
    guard let idx = activeIndex else { return nil }
    if sections.isEmpty { return "ws:\(idx)" }
    return sections.first {
        $0.sectionType == .workspace && $0.sourceWorkspaceIndex == idx
    }?.id
}
```

- [ ] **Step 4: Run to verify it passes** — `swift build` (local gate). Expected: PASS. (CI) `swift test --filter ActiveSectionIDTests` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FacetCore/ActiveSection.swift Tests/FacetCoreTests/ActiveSectionTests.swift
git commit -m ":sparkles: feat(core): activeSectionID 単一ハイライト判定ヘルパー (EX-2b.1)"
```

---

## Task EX-2b.2: rail renders the section list (carousel + hero union + single-highlight + pick routing)

**This is the deliverable, and necessarily one commit** (the `selectedWS → selectedSectionID` rename is load-bearing for the carousel geometry, so every reference migrates together; intermediate states do not compile). Implement all steps, then `swift build` once.

**Files:**
- New: `Sources/FacetViewRail/RailPick.swift`
- Modify: `Sources/FacetViewRail/RailView.swift`, `Sources/FacetViewRail/RailHeader.swift`, `Sources/FacetApp/Controller+Rail.swift`, `Sources/FacetApp/Controller.swift`

**Interfaces:**
- Produces: `RailPick` enum; `RailView.selectedSectionID: String?`; the carousel/hero built from `sections` with baked `isActive`.
- Consumes: `self.sections`/`self.activeLens` (stored, EX-2a), `OverviewCell.sectionType`/`sectionID`/`isLens` (EX-2a), `Controller.activateSection` (EX-1), `activeSectionID(...)` (EX-2b.1), `windowHomeWS`.

### Step 1 — `RailPick.swift` (new, mirror `GridPick`)

```swift
// What the user picked inside the rail carousel — mirrors GridPick so
// the Controller routes both surfaces through the same activateSection
// throughline. The window case carries the WINDOW's resolved home WS
// (0-based), NOT the cell's wsIndex (a window thumb may sit in a lens
// cell whose wsIndex is −1).
import FacetCore

public enum RailPick: Sendable {
    case workspace(workspaceIndex: Int)
    case lens(label: String)
    case window(homeWorkspaceIndex: Int, pid: Int, windowID: WindowID)
}
```

### Step 2 — RailView state: re-key cursor + add `windowHomeWS`/`sectionOrder`; re-key hover; new callback

In `RailView` stored props:
- Rename `public var selectedWS: Int?` → `public var selectedSectionID: String?` (update the doc comment to "the SECTION the centre hero previews").
- Add after it:
  ```swift
  /// EX-2b: window → home workspace index (0-based), rebuilt every
  /// layoutCells from the UNFILTERED `workspaces` snapshot. A window thumb
  /// may sit in a LENS cell (wsIndex=−1) but still has a real home WS;
  /// window picks resolve through this, never the cell's wsIndex.
  private var windowHomeWS: [WindowID: Int] = [:]
  /// EX-2b: the ordered section ids the carousel cycles (sources order,
  /// no peek-ghost dup), refreshed every layoutCells. Browse nav cycles
  /// this, not `cells` (which appends a wrap-peek ghost).
  private var sectionOrder: [String] = []
  ```
- Re-key hover: `private var hoverWS: Int?` → `private var hoverID: String?` (keep the `didSet { needsDisplay }`); `var hoverHeaderWS: Int?` → `var hoverHeaderID: String?`.
- Callbacks: **replace** `onPick: ((Int) -> Void)?` **and** `onPickWindow: ((_ ws:Int,_ pid:Int,_ id:WindowID)->Void)?` with a single:
  ```swift
  /// Pick a section cell / window thumb / commit a keyboard browse →
  /// the Controller routes through `activateSection`. (Replaces the old
  /// onPick(Int)+onPickWindow pair — EX-2b, mirrors the grid.)
  public var onPick: ((RailPick) -> Void)?
  ```
- Pending tuples re-key to the cell's `sectionID` (so the commit can resolve kind + home + the centred-hero check):
  ```swift
  var pendingDown: (point: NSPoint, hit: MiniWindowHit, cellID: String)?
  var pendingHeaderDown: (point: NSPoint, cellID: String)?
  ```

### Step 3 — `overviewCellSources()` + `CellSource` + `scaledWins([Window])`

Add a rail-local bridge mirroring the grid (the grid's is `private` to `FacetViewGrid`):

```swift
/// EX-2b: one cell source per projected section (workspace + lens), or
/// degrade to one per workspace when the section model is off here —
/// byte-identical to pre-EX-2b. `isActive` is the baked single-highlight
/// XOR (mirror of overviewCellSources in the grid / SidebarView.headerActive).
private struct CellSource {
    let wsIndex: Int            // 0-based; −1 for a lens (no source WS)
    let sectionType: SectionType
    let sectionID: String
    let label: String           // ws.name for a workspace; the bare lens label
    let mode: String            // layout engine; "" for a lens
    let windows: [Window]
    let isActive: Bool
}

private func overviewCellSources() -> [CellSource] {
    if sections.isEmpty {
        return workspaces.map { ws in
            CellSource(wsIndex: ws.index, sectionType: .workspace,
                       sectionID: "ws:\(ws.index)", label: ws.name,
                       mode: ws.layoutMode, windows: ws.windows,
                       isActive: activeLens == nil && ws.isActive)
        }
    }
    return sections.map { sec in
        let isLens = sec.sectionType == .lens
        let srcWS = sec.sourceWorkspaceIndex.flatMap { src in
            workspaces.first { $0.index == src } }
        let mode = isLens ? "" : (srcWS?.layoutMode ?? "")
        let active = isLens
            ? (activeLens != nil && sec.label == activeLens)
            : (activeLens == nil && srcWS?.isActive == true)
        return CellSource(wsIndex: sec.sourceWorkspaceIndex ?? -1,
                          sectionType: sec.sectionType, sectionID: sec.id,
                          label: sec.label, mode: mode,
                          windows: sec.windows, isActive: active)
    }
}
```

Change `scaledWins` to take `[Window]` (it no longer needs a `Workspace`):
```swift
private func scaledWins(_ windows: [Window], _ cell: NSRect,
                        _ screen: CGRect) -> [MiniWindowHit] {
    var out: [MiniWindowHit] = []
    for win in windows where !win.isLensParked {
        guard let f = win.frame else { continue }
        let r = scaledWindowRect(windowFrame: f, screenFrame: screen, cellRect: cell)
        guard r.width >= 2, r.height >= 2 else { continue }
        out.append(MiniWindowHit(pid: win.pid, id: win.id,
                          isFocused: win.isFocused, rect: r, mark: win.mark))
    }
    return out
}
```

### Step 4 — `layoutCells`: iterate sources, build the carousel + hero from the selected source

In `layoutCells(force:)`, **after** the drag-landing gate + the `guard !workspaces.isEmpty …` (keep the workspace-empty guard — degrade still needs a workspace snapshot; an empty desktop shows nothing), build the sources and the maps:

```swift
let sources = overviewCellSources()
sectionOrder = sources.map(\.sectionID)
windowHomeWS = [:]
for ws in workspaces { for w in ws.windows { windowHomeWS[w.id] = ws.index } }
let n = sources.count
```

> Replace the `let n = workspaces.count` with `sources.count`. All the geometry (`visible`, `bandCap`, `justRun`, slot, viewport, `railCarouselOffsets(count: n, …)`) stays — it is count-based.

`selectedPos` resolves through the section id, falling back to the **active** source (the lit one) then 0:
```swift
let selectedPos = sources.firstIndex { $0.sectionID == selectedSectionID }
    ?? sources.firstIndex { $0.isActive }
    ?? 0
```

Re-signature `placeCell` to take a `CellSource`:
```swift
func placeCell(_ src: CellSource, offset: Int) {
    // … identical slotStart / blockX / blockY / headerY / thumbY / rects …
    cells.append(OverviewCell(
        wsIndex: src.wsIndex, rect: cellRect, headerRect: headerRect,
        isActive: src.isActive, label: src.label, mode: src.mode,
        windows: scaledWins(src.windows, cellRect, useScreen),
        isHero: false, sectionType: src.sectionType, sectionID: src.sectionID))
}
for (i, src) in sources.enumerated() { placeCell(src, offset: offsets[i]) }
if n % 2 == 0, n > 1, n == visible, let li = offsets.firstIndex(of: -(n / 2)) {
    placeCell(sources[li], offset: n / 2)   // even-count wrap-peek ghost (same source)
}
```

Hero from the **selected** source (lens → union; workspace → its windows):
```swift
if heroBox.width > 1, heroBox.height > 1,
   let act = sources.first(where: { $0.sectionID == selectedSectionID })
        ?? sources.first(where: { $0.isActive })
        ?? sources.first {
    // … existing hCellW/hCellH aspect-fit + hx/hy centring …
    hero = OverviewCell(wsIndex: act.wsIndex, rect: hCellRect,
                headerRect: .zero, isActive: act.isActive,
                label: act.label, mode: act.mode,
                windows: scaledWins(act.windows, hCellRect, useScreen),
                isHero: true, sectionType: act.sectionType, sectionID: act.sectionID)
}
```

Stranded-cursor repair re-keys to `sectionID` (also seeds the cursor on first layout, since `selectedSectionID` starts `nil` — see Step 8):
```swift
if !cells.contains(where: { $0.sectionID == selectedSectionID }) {
    selectedSectionID = hero?.sectionID ?? cells.first?.sectionID
}
```

> The `aspect` for `scaledWins` mapping uses `useScreen` as today. A lens hero's union windows map by their real frames into the hero rect (declared cosmetic — see Deferred).

### Step 5 — `drawCell` + `commitSwitch` + window-ring + hover re-key

`drawCell`: the drop-target / swap-source / hero / `isActive` branches are **unchanged** (`isActive` is baked; lens cells never set `dropTargetWS`/`sourceWS`, which stay valid 0-based ws indices). Re-key the two `selectedWS == c.wsIndex` browse/hover branches + the window-ring gate:
```swift
} else if drag == nil && selectedSectionID == c.sectionID {   // browse target → secondary
    pal.secondary.setStroke(); path.lineWidth = 2
} else if hoverID == c.sectionID {                            // hover → faint
    pal.foreground.withAlphaComponent(0.7).setStroke(); path.lineWidth = 1.5
}
```
```swift
if drag == nil, let sel = kbSelectedWindow(),
   c.isHero || c.sectionID == selectedSectionID,
   let hit = c.windows.first(where: { $0.id == sel.id }) { … }
```

`commitSwitch` keys on the centred section:
```swift
private func commitSwitch(targetSectionID: String, perform: @escaping () -> Void) {
    guard !commitZoom.isActive else { return }
    guard targetSectionID == selectedSectionID, let h = hero,
          !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
          let img = snapshotRegion(h.rect)
    else { perform(); return }
    commitZoom.begin(image: img, from: h.rect,
                     redraw: { [weak self] in self?.needsDisplay = true }, perform: perform)
}
```

`mouseMoved`/`mouseExited` set `hoverID`/`hoverHeaderID` from `stripCellAt(p)?.sectionID` (header: only when the point is in `headerRect`).

### Step 6 — `RailHeader.swift`: re-key + lens cell (no grip, bare label)

```swift
let hover = hoverHeaderID == cell.sectionID
let kbWholeWS = drag == nil && kbSelectedWindowIdx == -1
    && selectedSectionID == cell.sectionID
// … browseTarget / pickColor / hot unchanged …
```
Grip dots only for workspace cells (a lens header is click-only):
```swift
if !cell.isLens {
    drawGripDots(in: …, color: …, alpha: …)
}
```
Name uses the bare lens label (the lens has no WS ordinal):
```swift
let name = cell.isLens ? cell.label : railLabel(cell.label, cell.wsIndex)
```
(The grip's left inset for the name `nameX` stays; for a lens the gripless band reads as a plain label — acceptable, matches the grid's lens header.)

### Step 7 — mouse + keyboard pick routing through `RailPick` + lens guards

`mouseDown`:
- Header: a lens header fires `.lens` immediately (never arms a swap); a workspace header arms `pendingHeaderDown`:
  ```swift
  if inStrip, let cell = cells.first(where: { $0.headerRect.contains(p) }) {
      if cell.isLens {
          commitSwitch(targetSectionID: cell.sectionID) { [weak self] in
              self?.onPick?(.lens(label: cell.label)) }
          return
      }
      pendingHeaderDown = (p, cell.sectionID); return
  }
  ```
- Hero window press: `pendingDown = (p, w, h.sectionID)`.
- Strip cell: window thumb → `pendingDown = (p, w, cell.sectionID)`; empty area → immediate switch:
  ```swift
  } else {
      commitSwitch(targetSectionID: cell.sectionID) { [weak self] in
          if cell.isLens { self?.onPick?(.lens(label: cell.label)) }
          else { self?.onPick?(.workspace(workspaceIndex: cell.wsIndex)) }
      }
  }
  ```

`mouseDragged` promotion — guard lens cells (no swap from / no move from a lens cell):
```swift
if let ph = pendingHeaderDown {
    // threshold …
    guard let src = cells.first(where: { $0.sectionID == ph.cellID }), !src.isLens else { return }
    let srcIDs = workspaces.first(where: { $0.index == src.wsIndex })?.windows.map(\.id) ?? src.windows.map(\.id)
    drag = OverviewDrag(sourceWS: src.wsIndex, kind: .workspace, …, srcIDs: srcIDs, …)
    …
} else if let pd = pendingDown {
    // threshold …
    guard let cell = cells.first(where: { $0.sectionID == pd.cellID }), !cell.isLens else { return }
    drag = OverviewDrag(sourceWS: cell.wsIndex, kind: .window, pid: pd.hit.pid, id: pd.hit.id, …)
    …
}
```
Drop-target computation excludes lens cells:
```swift
let over = stripCellAt(p)
d.dropTargetWS = (over?.isLens == true || over?.wsIndex == d.sourceWS) ? nil : over?.wsIndex
```

`mouseUp` click resolution:
```swift
if let pd = pendingDown {
    let cell = cells.first { $0.sectionID == pd.cellID }
    let home = windowHomeWS[pd.hit.id] ?? cell?.wsIndex ?? -1
    commitSwitch(targetSectionID: pd.cellID) { [weak self] in
        self?.onPick?(.window(homeWorkspaceIndex: home, pid: pd.hit.pid, windowID: pd.hit.id)) }
} else if let ph = pendingHeaderDown, let cell = cells.first(where: { $0.sectionID == ph.cellID }) {
    // workspace headers only (lens fired on mouseDown)
    commitSwitch(targetSectionID: ph.cellID) { [weak self] in
        self?.onPick?(.workspace(workspaceIndex: cell.wsIndex)) }
}
```
The drag-commit branch (`d.dropTargetWS` → `commitDrop`/`commitContentSwap`) is unchanged (operates on valid 0-based ws indices; `dstCell` looked up by `wsIndex` is a workspace cell since lens cells never become drop targets).

`kbMoveSelection(dx:)` cycles `sectionOrder`:
```swift
public func kbMoveSelection(dx: Int) {
    guard !commitZoom.isActive, !sectionOrder.isEmpty else { return }
    let m = sectionOrder.count
    let cur = sectionOrder.firstIndex(of: selectedSectionID ?? "") ?? 0
    let ni = (cur + dx + m) % m
    guard sectionOrder[ni] != selectedSectionID else { return }
    if drag == nil, let h = hero { prevHeroImage = snapshotRegion(h.rect); prevHeroRect = h.rect }
    selectedSectionID = sectionOrder[ni]
    if drag != nil { layoutCells(force: true); syncRailDragToSelection() }
    else { kbSelectedWindowIdx = -1; layoutCells(); startSlide(step: dx, slot: lastSlot) }
}
```
(`scrollRotate` guard `workspaces.count > 1` → `sectionOrder.count > 1`.)

`kbCommit` (not lifted) — window focus wins, then lens, then workspace:
```swift
guard let id = selectedSectionID,
      let cell = cells.first(where: { $0.sectionID == id }) else { return }
if let hit = kbSelectedWindow() {
    let home = windowHomeWS[hit.id] ?? cell.wsIndex
    commitSwitch(targetSectionID: id) { [weak self] in
        self?.onPick?(.window(homeWorkspaceIndex: home, pid: hit.pid, windowID: hit.id)) }
} else if cell.isLens {
    commitSwitch(targetSectionID: id) { [weak self] in
        self?.onPick?(.lens(label: cell.label)) }
} else {
    commitSwitch(targetSectionID: id) { [weak self] in
        self?.onPick?(.workspace(workspaceIndex: cell.wsIndex)) }
}
```

`kbLiftWorkspace` — reject lens:
```swift
guard drag == nil, let id = selectedSectionID,
      let cell = cells.first(where: { $0.sectionID == id }), !cell.isLens else { return }
let ws = cell.wsIndex
let srcIDs = workspaces.first(where: { $0.index == ws })?.windows.map(\.id) ?? cell.windows.map(\.id)
// … OverviewDrag(sourceWS: ws, kind: .workspace, …) …
```

`kbLiftWindow` — reject when the hero is a lens (a window in a lens view is not move-liftable):
```swift
guard drag == nil, let h = hero, !h.isLens, let sel = kbSelectedWindow() else { return }
let hit = cells.first(where: { $0.sectionID == selectedSectionID })?
    .windows.first(where: { $0.id == sel.id }) ?? sel
// … OverviewDrag(sourceWS: h.wsIndex, kind: .window, …) …
```

`syncRailDragToSelection` — lens aim → no drop target:
```swift
guard var d = drag, let id = selectedSectionID,
      let cell = cells.first(where: { $0.sectionID == id }) else { return }
d.dropTargetWS = (cell.isLens || cell.wsIndex == d.sourceWS) ? nil : cell.wsIndex
let at = NSPoint(x: cell.rect.midX, y: cell.rect.midY)
d.current = at; drag = d; positionDragGhost(at: at); needsDisplay = true
```

`kbContextMenu` — resolve the cell by id; lens header → no layout picker; window → home WS:
```swift
guard let backend, let win = window, let id = selectedSectionID,
      let cell = cells.first(where: { $0.sectionID == id }) else { return }
if kbSelectedWindowIdx == -1 {
    guard !cell.isLens else { return }              // lens has no layout engine
    // … showLayout(workspaceIndex: cell.wsIndex, …) …
} else if let h = hero, kbSelectedWindowIdx >= 0, kbSelectedWindowIdx < h.windows.count {
    let w = h.windows[kbSelectedWindowIdx]
    let ws = windowHomeWS[w.id] ?? cell.wsIndex
    // … railWinMenu(scr, backend, ws: ws, w: w) …
}
```

`rightMouseDown` — header lens guard + window home WS (mirror grid's whole-branch fix):
```swift
if inStrip, let cell = cells.first(where: { $0.headerRect.contains(p) }) {
    guard !cell.isLens else { return }              // lens header → no layout picker
    ViewContextMenu.showLayout(at: scr, backend: backend, workspaceIndex: cell.wsIndex, …)
    return
}
if let w = heroWinAt(p), let h = hero {
    railWinMenu(scr, backend: backend, ws: windowHomeWS[w.id] ?? h.wsIndex, w: w); return
}
if inStrip, let cell = cells.first(where: { $0.rect.contains(p) }),
   let w = cell.windows.reversed().first(where: { $0.rect.contains(p) }) {
    railWinMenu(scr, backend: backend, ws: windowHomeWS[w.id] ?? cell.wsIndex, w: w)
}
```

### Step 8 — Controller wiring: `onPick` → `activateSection`; rail feed re-centre

`Controller+Rail.showRail`: **drop** `rv.selectedWS = rv.activeIndex` (the cursor is seeded by the layout fallback + stranded-repair — `selectedSectionID` starts `nil`, the first `layoutCells` centres on the active source and the repair sets the id). **Replace** the `rv.onPick`(Int) + `rv.onPickWindow` closures with one `RailPick` closure mirroring the grid:
```swift
rv.onPick = { [weak self, bk = backend] pick in
    guard let self else { return }
    switch pick {
    case .workspace(let ws):
        self.activateSection(.workspace(ws + 1), autoFocus: true)
    case .lens(let label):
        self.activateSection(.lens(label), autoFocus: true)
    case .window(let home, let pid, let id):
        if home >= 0 { self.activateSection(.workspace(home + 1), autoFocus: false) }
        cliQueue.async {
            let win = Window(id: id, pid: pid, appName: "", title: "",
                             isFocused: false, isFloating: false, frame: nil)
            Focus.assert(win, backend: bk)
        }
    }
    self.hideRail()
}
```
> `activateSection` runs the mirror update on main + the backend op itself (it is NOT wrapped in `cliQueue` here — exact mirror of the grid's `onPick`). The old rail wrapped `bk.switchWorkspace` in `cliQueue`; `activateSection` owns that split internally.

`Controller.swift` rail feed (the `if let rv = railView` block ~915): generalise the re-centre to the section cursor:
```swift
if let rv = railView {
    let oldActiveID = activeSectionID(activeLens: rv.activeLens,
                                      activeIndex: rv.activeIndex, sections: rv.sections)
    rv.workspaces = wss
    rv.activeIndex = wss.first(where: { $0.isActive })?.index
    rv.sections = lastSections
    rv.activeLens = lastActiveLens
    // 2-b carousel: an EXTERNAL activate (CLI / lens) while the rail is
    // open re-centres on the new active SECTION — but only when the user
    // isn't mid-browse (cursor still on the old active), so a manual
    // rotation isn't yanked back. (EX-2b: generalises selectedWS==oldActive.)
    let newActiveID = activeSectionID(activeLens: rv.activeLens,
                                      activeIndex: rv.activeIndex, sections: rv.sections)
    if rv.selectedSectionID == oldActiveID, let n = newActiveID {
        rv.selectedSectionID = n
    }
    rv.layoutCells()
}
```

### Step 9 — Build

Run: `swift build`. Expected: PASS. Resolve any straggler `selectedWS`/`hoverWS`/`onPickWindow` references (grep `selectedWS`, `hoverWS`, `hoverHeaderWS`, `onPickWindow` across `Sources/FacetViewRail` + `Sources/FacetApp` → **must be ZERO** after this task).

### Step 10 — Commit

```bash
git add Sources/FacetViewRail/RailPick.swift Sources/FacetViewRail/RailView.swift \
        Sources/FacetViewRail/RailHeader.swift Sources/FacetApp/Controller+Rail.swift \
        Sources/FacetApp/Controller.swift
git commit -m ":sparkles: feat(rail): section/lens cell カルーセル + hero union + 単一ハイライト + activateSection 経由化 (EX-2b.2)"
```

---

## Task EX-2b.3: docs — 3-view parity complete

**Files:** `config.toml`, `docs/glossary.md`, `docs/architecture.md`, `README.md`, `README.ja.md`

- [ ] **Step 1**
  - `config.toml`: in the `[[desktop.N.section]]` / lens commentary, note lens sections now render as **carousel cells in the rail** (and the active lens becomes the centre **hero** showing its union) — completing tree + grid + rail parity.
  - `docs/glossary.md`: under `### lens` / `### active section`, broaden any "tree + grid" wording to **all three views**; remove any "rail renders workspaces only" note; document the rail hero-union-under-lens.
  - `docs/architecture.md`: the two-machineries / 3-view table — mark the **rail** as a section-list consumer (the EX-2a "grid pending; rail EX-2b" note is now resolved). State the EX-2 deliverable (3-view unified highlight) complete.
  - `README.md` + `README.ja.md`: if the rail/views section claims rail is workspace-only, update to "the rail renders the same section list as the tree and grid, including lenses, with the active section as the hero." Keep bilingual in sync ([[readme-bilingual]]).

- [ ] **Step 2: Build** — `swift build` (docs-only; trivially green; confirms no accidental source edit).

- [ ] **Step 3: Commit**

```bash
git add config.toml docs/glossary.md docs/architecture.md README.md README.ja.md
git commit -m ":memo: docs(rail): lens cell + hero union の 3-view parity を反映 (EX-2b.3)"
```

---

## EX-2b host-verify (トミー operates; synthetic input only with fresh consent)

Build + run; on a mac desktop whose ordinal has a `[[desktop.N.section]]` block with **both** a `type="workspace"` and a `type="lens"` section (the `config.toml` ACTIVE SAMPLE `desktop.1`: 2 workspaces + Web/Code/Chat lenses). Re-grant AX if `./run.sh` re-sign dropped it. Confirm on screen + `/tmp/facet.log`:

1. **Lens cells render in the carousel.** `facet --view rail` → the strip shows the workspace cells **and** the lens cells (Web/Code/Chat). Browse arrows (←/→ on a bottom rail) rotate through **all** of them; the centred one is the hero.
2. **Single-highlight, no lens active.** No lens active → exactly the active *workspace* cell is lit (`pal.primary`); lens cells muted. At rest the hero = the active workspace.
3. **Single-highlight, lens active + hero union.** `facet lens "Web"`, then `facet --view rail` → exactly the **Web** lens cell is lit; **all workspace cells muted**; the **hero renders the Web union** (Chrome/Safari windows from both workspaces). (Decision 1 + the EX-2a declared gap is now closed — confirm no workspace cell shows the primary accent.)
4. **Browse onto a lens → it becomes the hero.** With no lens active, arrow to a lens cell → the hero re-renders that lens's union (secondary accent while browsed-not-active); Return activates the lens (`/tmp/facet.log`: `setSectionLens "<lens>" visible=N` + union tile + autoFocus); the rail dismisses.
5. **Click a workspace cell switches + clears.** With Web active, click/Return a workspace cell → switches to that WS, lens clears (`engine WS N frames=…`, parked windows restored), the now-active workspace is the lit + hero section.
6. **Click a window thumb focuses it (workspace hero).** Click a window thumb in the hero / a strip workspace cell → switches to its WS + focuses that window.
6b. **Click/Tab a window thumb INSIDE a lens hero (MUST-FIX #1 analog).** With Web active (hero = union), click a Chrome window thumb in the hero (or Tab to it + Return) → switches to **that window's home workspace**, clears the lens, focuses the window — NOT a no-op. (windowHomeWS resolves the real home, never the lens cell's −1.)
7. **Lens cell is not a drag target — mouse AND keyboard.** Drag a window thumb onto a lens cell (mouse) → no move. Lift a workspace (Space on a workspace header) then arrow onto a lens cell + Return → no swap (drop cancels). Drag/lift a **lens header** → no swap starts (no grip dots shown on lens headers).
8. **Right-click guards.** Right-click a lens header → **no** layout picker. Right-click a window in a lens hero → window-ops menu with the **correct home WS**. Right-click a workspace header → layout picker (positive control).
9. **Persistent re-light + re-centre.** With the rail open and a workspace centred, run `facet lens "Web"` externally → the rail re-lights the Web cell + re-centres the hero to the Web union (cursor was at rest). Then arrow away to a workspace and run `facet lens "Code"` → the rail re-lights Code but does **not** yank the browse cursor (cursor was mid-browse).
10. **Degrade unchanged.** On a mac desktop with NO `[[desktop.N.section]]` block, `facet --view rail` renders exactly as before (workspace cells + hero, active one lit, carousel browse unchanged).

Record results in the SDD ledger. **push/merge awaits トミー go.**

---

## Self-Review

**1. Spec coverage** (parent plan EX-2 row, rail half + Decision 2 + Decision 1):
- "render lens sections as cells (rail)" → EX-2b.2 Step 4 (carousel iterates sources). ✓
- "hero = active/selected section; lens → union" → EX-2b.2 Step 4 hero from selected source; Decision 1 (トミー). ✓
- "click any window/cell → activate+focus (rail)" → EX-2b.2 Step 7 + Step 8 (`RailPick` → `activateSection`; window thumb → home WS + `Focus.assert`). ✓
- "unified highlight 3-view" → EX-2b.2 baked `isActive` XOR + re-key; the EX-2a declared gap (rail lights active-WS under a lens) is closed. Tree (EX-1) + grid (EX-2a) + rail (EX-2b) all single-highlight. ✓
- Pure helper + Controller re-centre (persistent rail) → EX-2b.1 + EX-2b.2 Step 8. ✓

**2. Placeholder scan:** No "TBD"/"similar to". Every step shows the code or names the exact symbol + edit, grounded in the 2026-06-22 source read + codemap `wf_fc77532c-8d2`. ✓

**3. Type consistency:** `RailPick` mirrors `GridPick` (0-based indices, +1 at the Controller). `selectedSectionID: String?` / `hoverID` / `hoverHeaderID` / `sectionOrder: [String]` / `windowHomeWS: [WindowID: Int]` consistent across RailView + RailHeader. `CellSource.windows: [Window]`; `scaledWins([Window])`. `activeSectionID(...) -> String?` matches `overviewCellSources`'s XOR. The +1 lives only in `Controller+Rail` (mirror grid). ✓

**4. Risks re-checked against the codemap:**
- `workspaces` snapshot retained (windowHomeWS authority, swap source, landing gate) — Constraints + Steps 3/7 keep it. ✓
- `railCarouselOffsets`/`railBands`/Tunables unchanged (count-based) — codemap `rail-geometry-pure` confirmed empty `ex2bChanges`. ✓
- Lens cells never become `dropTargetWS`/`sourceWS` (always valid 0-based) — guarded in `mouseDragged`, `syncRailDragToSelection`, `kbLiftWorkspace`, `kbLiftWindow`; `dropTargetWS == -1` impossible → no `commitDrop`/`commitContentSwap` with `dstCell.wsIndex == -1`. ✓
- The +1 trap (Constraints + Step 8). ✓
- Carousel nav over `sectionOrder` (no peek-ghost dup), not `cells`. ✓
- Hero/`commitSwitch`/window-ring re-keyed to `sectionID` (lens cells share `wsIndex == −1`). ✓
- Persistent re-centre uses `activeSectionID` before/after the field update (old vs new active id). ✓

**5. Grid-parity must-fixes pre-folded** (the EX-2a whole-branch review found 3 MOUSE-path guards the keyboard path already had — pre-empted here so the rail doesn't repeat them):
- **MF1 analog** (window-in-lens home WS): `rightMouseDown` + `mouseUp`/`kbCommit` window picks resolve `windowHomeWS[id] ?? cell.wsIndex`, never the cell's `−1`; Controller guards `home >= 0`. Host-verify 6b. ✓
- **MF2 analog** (lens cell as a drop target): guarded in BOTH mouse (`mouseDragged` `over?.isLens`) and keyboard (`syncRailDragToSelection`, `kbLiftWorkspace`). Host-verify 7. ✓
- **MF3 analog** (lens header layout picker): `rightMouseDown` + `kbContextMenu` guard `!cell.isLens`. Host-verify 8. ✓
- **Hover collision** (lens cells share `wsIndex == −1` → one hover lights all): re-keyed `hoverWS`/`hoverHeaderWS` → `hoverID`/`hoverHeaderID` (sectionID). ✓
- **Lens header grip dots** (implies draggable): suppressed (`if !cell.isLens`). ✓

**6. Why EX-2b.2 is one commit (not split like the grid's 2.3/2.5/2.6):** the rail centres the carousel on the browse cursor, so `layoutCells` depends on `selectedSectionID`; the `selectedWS → selectedSectionID` type change (Int? → String?) breaks every comparison at once and cannot stay build-green half-migrated. The grid could split because its `kbSelectedWS` was decoupled from layout. Recorded so a reviewer doesn't flag the coarse split as a process miss.
