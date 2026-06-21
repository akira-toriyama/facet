# EX-1 — ActiveSection Authority + Single-Highlight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. This is the **detailed re-plan of the EX-1 row** in [2026-06-21-exclusive-model-revised-plan.md](2026-06-21-exclusive-model-revised-plan.md), refreshed against the EX-0 foundation (main `5c15d3d`, PR #314). The parent plan's EX-0→EX-4 phase split is unchanged; this doc only expands EX-1.

**Goal:** Introduce a single `ActiveSection` concept (`activeLens XOR activeWorkspace`), make the active-section authority flow from the catalog through one read-back so the Controller's `currentActiveLens` double-source-of-truth disappears, route both lens- and workspace-activation through one backend throughline (`activateSection`), and make the tree light **exactly one** active-section highlight. Plus the lens `layout` config/docs/glossary surface and the documented startup invariant.

**Architecture:** EX-0 already made the catalog *state* exclusive (every `setActive` nulls `activeSectionLens`; `facet lens` gathers cross-workspace). EX-1 names that exclusivity as `enum ActiveSection { case workspace(Int); case lens(String) }` in pure FacetCore, derives it at the catalog seam, mirrors it through one lock-guarded adapter read-back (`currentActiveSection()`), and consumes it in the Controller as one typed field (`currentActiveSection`) — eliminating the EX-0.5-patched stale-mirror bug structurally. Activation funnels through `WindowBackend.activateSection(_:autoFocus:)`. The tree's `headerActive` gains a one-line exclusivity gate.

**Tech Stack:** Swift 6, macOS 13+, SwiftPM. 3-layer spine: `FacetCore` (pure) / `FacetAdapterNative` (AX + catalog, `cliQueue`-confined) / `FacetView*` + `FacetApp` (GUI/Controller). Tests are XCTest, **CI-only** (local gate is `swift build`).

## Global Constraints

- **Layer spine is non-negotiable.** `FacetCore` pure (CoreGraphics OK, no AppKit / no AX / no backend types). `ActiveSection` is pure FacetCore. `FacetAdapterNative` is the only place AX/CGS/catalog types appear. Views talk to `WindowBackend`, never a concrete adapter. ([[facet-architecture-decisions]])
- **Catalog is the single state authority.** active-section / park sets live in `WorkspaceCatalog` (mutated only on `cliQueue`); views read a snapshot or a lock-guarded mirror. No view-side recompute that can drift.
- **All TOML keys clamp, never reject.** Lens `layout` typos clamp via `LensLayout.resolve` (already shipped EX-1a). Read through `effective*` accessors. ([[config-default-behavior]])
- **Loud on typo, silent on success.** Unknown lens NAME → operational error surfaced via status (already in `setActiveLens`). ([[control-is-cli-first]])
- **Tests compile in CI only.** Write XCTest defensively. **Any test that calls a `cliQueue`-guarded adapter method MUST wrap it in `cliQueue.sync { … }`** or `dispatchPrecondition` aborts the CI debug build (EX-0.3 lesson — `swift build` cannot catch this). Local gate is `swift build`. ([[feedback-swift-tests-only-compile-in-ci]])
- **No push/merge without an explicit OK from トミー.** Commit locally on `feat/ex1-active-section`; squash-merge only on go. ([[pr-conventions]], [[grid-view-work-style]])
- **Glossary terms are canonical.** `active section` is a NEW term EX-1 adds; `lens` broadens to cover the section model. Add/rename in the same PR as the code. ([docs/glossary.md](../../glossary.md))
- **README is bilingual.** [README.md](../../../README.md) (EN) + [README.ja.md](../../../README.ja.md) (JA) update in the same commit. ([[readme-bilingual]])
- **Patch by SYMBOL, not line number.** Earlier audits found systematic line drift; all line numbers below are *as of main `5c15d3d`* and must be re-located by symbol before editing.

---

## EX-0 foundation recap (what EX-1 builds on)

Verified in source at main `5c15d3d`:

- `WorkspaceCatalog.activeIndex: Int = 1` (1-based, `private(set)`) is always set; `activeSectionLens: String?` is nil ⇔ a workspace is the active section. The XOR is **already structural**: `setActive(_:in:)` nulls `activeSectionLens` + `activeSectionLensLayout` + `lensParkedMembers` on every *real* switch.
- ⚠️ `setActive` line 554: `guard isValid(n1Based), n1Based != activeIndex else { return nil }` — a **same-index switch is a no-op and does NOT clear the lens**. (Drives the EX-1.2 same-index-clear edge below.)
- `NativeAdapter` keeps a lock-guarded `_activeSectionLensLabel` mirror, refreshed by `syncSectionLensMirror()` (called in `switchWorkspace`, `setSectionLens`, `applySectionLensReconcile`/`refreshCatalog`), read on the main actor via `currentSectionLens()`.
- `switchWorkspace(toIndex:)` is **0-based** (`target = index + 1`) and already calls `syncSectionLensMirror()`.
- `Controller.currentActiveLens: String?` is a third copy (the double-SSOT). `apply()` re-reads it from `backend.currentSectionLens()` on `macDesktopSwapped || wsSwitched`. The idempotent guard `guard currentActiveLens != label` (Controller+CLIDispatch.swift:551) is the EX-0.5 stale-mirror false-swallow site (symptomatically patched).
- `WindowBackend` (Backend.swift): protocol-body decls + a `public extension WindowBackend` (line 560) with default impls (`setSectionLens` no-op:585, `currentSectionLens` `nil`:628). Test stubs (`StubBackend` BackendTests.swift:13, `FocusStub`) inherit defaults — **new protocol methods with extension defaults won't break them**.
- Tree double-highlight: `SidebarView.headerActive` (SidebarView.swift:569-572) lights a workspace section by `wsActive(...)` AND a lens section by `label == activeLens` independently — both lit when a lens is active.
- Lens `layout` key: parsed (`DesktopSection.parse`, EX-1a) + resolved (`LensLayout.resolve`/`isStateless`) + applied (`resolvedLensLayout`, EX-0.2/0.3). **Fully functional; only undocumented.**
- Startup: fresh catalog → `activeIndex=1`, `activeSectionLens=nil`; no boot path sets a lens. First `apply()` does not fire the read-back. So "first workspace is the active section at boot" is already true by zero-value default — EX-1 only pins + documents it.

---

## Design decisions locked (this re-plan)

These are implementation-shape calls delegated to Claude by the design canon ([[facet-tag-unification-design]]: "CLI 詳細の綴り・tree の見た目・実装フェーズの刻み方は全てクロード委任"). The product design (exclusive model, single-highlight, startup=first-workspace, CLI 2-system collapse is EX-4) was grilled (14 decisions, all YES) and is not re-opened.

1. **`ActiveSection` is a derived concept, not a stored field (yet).** Add `enum ActiveSection` in FacetCore + a `WorkspaceCatalog.activeSection` **computed property** (`activeSectionLens.map(.lens) ?? .workspace(activeIndex)`). Do NOT replace the underlying `activeSectionLens`/`activeIndex` fields — they are load-bearing across 30+ sites; field consolidation is deferred to EX-3/EX-4 when the catalog is otherwise restructured. (Lowest-risk way to get the concept.)
2. **One adapter mirror, two reads.** Consolidate `_activeSectionLensLabel` → `_activeSection: ActiveSection` under the existing `sectionLensLock`. `currentActiveSection()` reads it; `currentSectionLens()` becomes a `.lensLabel` shim. This removes a mini-SSOT inside the adapter and is always-current (synced on `cliQueue` before the refresh event).
3. **`activateSection` is the backend throughline.** Add `WindowBackend.activateSection(_ section: ActiveSection, autoFocus:)` (extension default no-op). NativeAdapter routes `.workspace(n)` → `switchWorkspace(toIndex: n-1)` (or explicit lens-clear on the same-index edge) and `.lens(label)` → `setSectionLens(label)`. Lens **clear** (`nil`) stays on `setSectionLens(nil)` — a clear is a *deactivation* (return to the active workspace without switching it), not an activation. EX-2 extends the same seam to grid/rail; EX-4 collapses the user-facing CLI to it.
4. **Controller holds one typed field.** Replace `currentActiveLens: String?` → `currentActiveSection: ActiveSection = .workspace(1)`. Idempotent guard becomes `currentActiveSection != .lens(label)` (structurally un-stale: `.workspace(N) != .lens(label)`). apply() read-back reads `backend.currentActiveSection()`. This resolves the EX-0.5 double-SSOT at the root.
5. **Tree single-highlight is a one-line `headerActive` gate** + routing the workspace-header click through `bk.activateSection`. The view already holds `bk`, so no new `TreeController` protocol method is needed in EX-1.
6. **`ActiveSection.workspace(Int)` is 1-based** (matches `catalog.activeIndex` + `facet workspace --focus N`). NativeAdapter converts to `switchWorkspace`'s 0-based at the seam.

### Deferred to EX-2+ (declared, not dropped — 未達成を暗黙にしない)

- **grid/rail single-highlight** (suppress the active-workspace cell accent when a lens is active) → **EX-2**, bundled with rendering lens sections as grid/rail cells ("one unified highlight 3-view" is the EX-2 deliverable). Sidesteps the rail-hero-cell demotion visual judgment for now. Today grid/rail still light the active workspace cell while a lens is active — a known cosmetic gap, acceptable because grid/rail cannot show lens sections until EX-2.
- **Optimistic single-highlight on a *tree workspace-header* click while a lens is active** — clears via the backend round-trip (≈one reconcile lag), same as today's switch. The lens-header toggle and the CLI paths ARE optimistic. Full optimism for the workspace-header click waits for the EX-2 `TreeController` unification.
- **Relative workspace switches** (`--focus recent/next/prev`) keep `switchWorkspaceRelative` (they clear the lens correctly via `setActive`; highlight updates via the apply() read-back). Folding them into `activateSection` is EX-4 CLI-unification work.
- **Catalog field consolidation** (`activeSectionLens`/`activeIndex` → a single stored `ActiveSection`) → EX-3/EX-4.
- **Backend `updateConfig` auto-clear of a now-undefined active lens** — if a config hot-reload removes the `type="lens"` section that is currently active, `catalog.activeSectionLens` stays set while `sectionLensFilter()` returns nil (stale/empty union until the next switch). Pre-existing #313 debt the ledger flags as EX-1-surface MINOR BACKLOG. EX-1.3 Step 9 clears the *Controller* mirror (`reloadConfig`); the *adapter* auto-clear (`NativeAdapter.updateConfig` → `if catalog.activeSectionLens != nil && sectionLensFilter() == nil { setSectionLens(nil) }`) is **deferred to EX-2/backlog** (not silently dropped). Low user impact (only triggers on a live config edit that deletes the active lens).

---

## File structure

| File | Responsibility | Task |
|---|---|---|
| `Sources/FacetCore/ActiveSection.swift` (NEW) | The `ActiveSection` enum + `lensLabel` helper. Pure. | EX-1.1 |
| `Sources/FacetAdapterNative/WorkspaceCatalog.swift` | `activeSection` computed property. | EX-1.1 |
| `Sources/FacetCore/Backend.swift` | `activateSection` + `currentActiveSection` protocol decls + extension defaults. | EX-1.2 |
| `Sources/FacetAdapterNative/NativeAdapter.swift` | mirror consolidation, `currentActiveSection()`, `currentSectionLens()` shim, `activateSection(_:autoFocus:)` impl. | EX-1.2 |
| `Sources/FacetApp/Controller.swift` | `currentActiveSection` field + comment; apply() read-back; tree render `activeLens`; `activeWSIndex(in:)` helper; `reloadConfig` clear. | EX-1.3 |
| `Sources/FacetApp/Controller+CLIDispatch.swift` | `setActiveLens`, `dispatchWorkspace`, `activateSection(_:)` Controller method, idempotent guard. | EX-1.3 |
| `Sources/FacetApp/Controller+ActiveMode.swift` | `toggleActiveLens` reimplemented over `currentActiveSection`. | EX-1.3 |
| `Sources/FacetViewTree/SidebarView.swift` | `headerActive` exclusivity gate. | EX-1.4 |
| `Sources/FacetViewTree/SidebarView+Drag.swift` | workspace-header click → `bk.activateSection`. | EX-1.4 |
| `config.toml`, `Sources/FacetCore/FacetConfig+Spec.swift`, `config.schema.json`, `docs/glossary.md`, `docs/architecture.md`, `README.md`, `README.ja.md` | doc surface + lens `layout` Spec/schema. | EX-1.5 |
| `Tests/FacetCoreTests/ActiveSectionTests.swift` (NEW) | enum behavior. | EX-1.1 |
| `Tests/FacetAdapterNativeTests/SectionLensCatalogTests.swift` | catalog `activeSection` + startup invariant. | EX-1.1 |
| `Tests/FacetAdapterNativeTests/ActiveSectionAdapterTests.swift` (NEW) | adapter read-back + `activateSection` routing (incl. same-index-clear edge). | EX-1.2 |

Execution: one branch `feat/ex1-active-section`. Sub-task = one commit, TDD where testable, adversarial review per sub-task. **ONE host-verify after all five** (トミー operates; synthetic input NG).

---

## Task EX-1.1: `ActiveSection` enum + catalog `activeSection` + startup invariant

**Files:**
- Create: `Sources/FacetCore/ActiveSection.swift`
- Modify: `Sources/FacetAdapterNative/WorkspaceCatalog.swift` (add `activeSection` computed property near `activeSectionLens` ~line 351)
- Test: `Tests/FacetCoreTests/ActiveSectionTests.swift` (new), `Tests/FacetAdapterNativeTests/SectionLensCatalogTests.swift` (extend)

**Interfaces:**
- Produces: `public enum ActiveSection: Equatable, Sendable { case workspace(Int); case lens(String) }` with `public var lensLabel: String?`; `WorkspaceCatalog.activeSection: ActiveSection` (computed).
- Consumes: nothing (additive, no behavior change).

- [ ] **Step 1: Write the failing FacetCore test**

```swift
// Tests/FacetCoreTests/ActiveSectionTests.swift
import XCTest
@testable import FacetCore

final class ActiveSectionTests: XCTestCase {
    func testLensLabelExtractsLabel() {
        XCTAssertEqual(ActiveSection.lens("Web").lensLabel, "Web")
    }
    func testLensLabelNilForWorkspace() {
        XCTAssertNil(ActiveSection.workspace(2).lensLabel)
    }
    func testEqualityDiscriminatesCases() {
        XCTAssertNotEqual(ActiveSection.workspace(1), ActiveSection.lens("1"))
        XCTAssertEqual(ActiveSection.workspace(3), ActiveSection.workspace(3))
        XCTAssertNotEqual(ActiveSection.workspace(2), ActiveSection.workspace(3))
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `swift build` then (CI) `swift test --filter ActiveSectionTests`. Expected: compile FAIL ("cannot find 'ActiveSection'"). Locally `swift build` fails to find the type. (Tests run CI-only; locally confirm the build error then implement.)

- [ ] **Step 3: Create the enum**

```swift
// Sources/FacetCore/ActiveSection.swift
/// The single active-section concept (EX-1): exactly one section is active
/// at a time — a `type="lens"` section (cross-workspace union) when one is
/// set, else the active workspace (the always-present spatial slot). The
/// catalog enforces the XOR invariant structurally (every workspace switch
/// nulls the active lens, EX-0.4); this enum names it so all three layers
/// share one vocabulary instead of "`activeIndex: Int` + `activeSectionLens:
/// String?`". See docs/glossary.md `### active section`.
public enum ActiveSection: Equatable, Sendable {
    /// The active workspace, by **1-based** index — matches
    /// `WorkspaceCatalog.activeIndex` and the user-facing `facet workspace
    /// --focus N` ordinal. The adapter converts to `switchWorkspace`'s
    /// 0-based convention at the seam.
    case workspace(Int)
    /// The active `type="lens"` section, keyed by its config `label`.
    case lens(String)

    /// The lens label when a lens section is active, else `nil`. Lets
    /// lens-only readers (`currentSectionLens()`, the tree `activeLens`
    /// highlight) derive their value from the unified concept.
    public var lensLabel: String? {
        if case .lens(let label) = self { return label }
        return nil
    }
}
```

- [ ] **Step 4: Run to verify FacetCore test passes** — `swift build` clean; (CI) `ActiveSectionTests` green.

- [ ] **Step 5: Write the failing catalog test** (extend `SectionLensCatalogTests` — WorkspaceCatalog is a struct, methods called directly, **no `cliQueue.sync` needed** at the catalog level):

```swift
// ⚠️ WorkspaceConfig has NO zero-arg init — only `init(name:layout:)`
// (FacetConfig.swift:30). Use `WorkspaceConfig(name: "")` (the
// Fixtures.swift:35 / seededCatalog pattern). Better: reuse the shared
// `seededCatalog(2)` helper (Fixtures.swift:32) instead of hand-seeding.
func testActiveSectionIsWorkspaceOneAtInit() {
    let cat = seededCatalog(2)                         // Fixtures.swift
    XCTAssertEqual(cat.activeSection, .workspace(1))   // startup invariant
}
func testActiveSectionReflectsActiveLens() {
    var cat = seededCatalog(2)
    cat.activeSectionLens = "Web"
    XCTAssertEqual(cat.activeSection, .lens("Web"))
}
func testActiveSectionFollowsWorkspaceSwitchAndClearsLens() {
    var cat = seededCatalog(2)
    cat.activeSectionLens = "Web"
    _ = cat.setActive(2, in: CGRect(x: 0, y: 0, width: 1600, height: 900)) // real switch clears the lens
    XCTAssertEqual(cat.activeSection, .workspace(2))
    XCTAssertNil(cat.activeSectionLens)
}
```

(If `seededCatalog` isn't visible from `SectionLensCatalogTests`, hand-seed with `WorkspaceConfig(name: "")`: `cat.seed(configs: [(index: 1, config: WorkspaceConfig(name: "")), (index: 2, config: WorkspaceConfig(name: ""))])`. Never `.init()` — it does not compile.)

- [ ] **Step 6: Run to verify catalog test fails** — `swift build` FAIL ("value of type 'WorkspaceCatalog' has no member 'activeSection'").

- [ ] **Step 7: Add the catalog computed property** (in `WorkspaceCatalog.swift`, immediately after `var activeSectionLens: String?` ~line 351):

```swift
/// The single active-section concept (EX-1): a lens when one is active,
/// else the active workspace. DERIVED — `activeSectionLens` / `activeIndex`
/// stay the load-bearing stored fields (the XOR is enforced by `setActive`
/// nulling the lens, EX-0.4; field consolidation is deferred to EX-3/EX-4).
/// Read by the adapter mirror (`syncSectionLensMirror`) to drive the
/// Controller's single active-section highlight.
var activeSection: ActiveSection {
    activeSectionLens.map(ActiveSection.lens) ?? .workspace(activeIndex)
}
```

- [ ] **Step 8: Run to verify all EX-1.1 tests pass** — `swift build` clean; (CI) `ActiveSectionTests` + the 3 new catalog tests green.

- [ ] **Step 9: Commit**

```bash
git add Sources/FacetCore/ActiveSection.swift \
        Sources/FacetAdapterNative/WorkspaceCatalog.swift \
        Tests/FacetCoreTests/ActiveSectionTests.swift \
        Tests/FacetAdapterNativeTests/SectionLensCatalogTests.swift
git commit -m ":sparkles: feat(core): ActiveSection enum + catalog activeSection (EX-1.1)"
```

---

## Task EX-1.2: Adapter authority — one mirror, `currentActiveSection()`, `activateSection` throughline

**Files:**
- Modify: `Sources/FacetCore/Backend.swift` (protocol decls near `setSectionLens`:234 / `currentSectionLens`:510; extension defaults near :585 / :628)
- Modify: `Sources/FacetAdapterNative/NativeAdapter.swift` (mirror ~278-291; new `activateSection` near `switchWorkspace`/`setSectionLens`)
- Test: `Tests/FacetAdapterNativeTests/ActiveSectionAdapterTests.swift` (new)

**Interfaces:**
- Consumes: `ActiveSection` (EX-1.1), `WorkspaceCatalog.activeSection` (EX-1.1).
- Produces: `WindowBackend.activateSection(_ section: ActiveSection, autoFocus: Bool)`, `WindowBackend.currentActiveSection() -> ActiveSection`. `currentSectionLens()` retained as a `.lensLabel` shim (existing callers unchanged).

- [ ] **Step 1: Write the failing adapter test** (adapter methods are `cliQueue`-guarded → **every call wrapped in `cliQueue.sync`**; construct the adapter via the existing `Fixtures.swift` `adapter()` helper):

```swift
// Tests/FacetAdapterNativeTests/ActiveSectionAdapterTests.swift
import XCTest
@testable import FacetAdapterNative
import FacetCore

final class ActiveSectionAdapterTests: XCTestCase {
    func testCurrentActiveSectionDefaultsToWorkspaceOne() {
        let a = adapter()                                  // fresh, no lens
        XCTAssertEqual(a.currentActiveSection(), .workspace(1))
        XCTAssertNil(a.currentSectionLens())               // shim agrees
    }

    func testActivateLensReflectsInMirror() {
        let a = adapterWithWebLensAndWorkspace()           // see fixture note ↓
        cliQueue.sync { a.activateSection(.lens("Web"), autoFocus: false) }
        XCTAssertEqual(a.currentActiveSection(), .lens("Web"))
        XCTAssertEqual(a.currentSectionLens(), "Web")      // shim agrees
    }

    func testActivateWorkspaceSameIndexClearsActiveLens() {
        // The same-index-clear edge: setActive(activeIndex) is a no-op, so
        // activateSection(.workspace(activeIndex)) must clear the lens explicitly.
        let a = adapterWithWebLensAndWorkspace()
        cliQueue.sync { a.activateSection(.lens("Web"), autoFocus: false) }
        XCTAssertEqual(a.currentActiveSection(), .lens("Web"))
        cliQueue.sync { a.activateSection(.workspace(1), autoFocus: false) } // 1 == activeIndex
        XCTAssertEqual(a.currentActiveSection(), .workspace(1))
        XCTAssertNil(a.currentSectionLens())               // lens cleared, not left stale
    }
}
```

> ⚠️ FIXTURE (load-bearing — a bare `adapter()` makes these tests VACUOUS):
> `setSectionLens` guards on `config.isSectionModelActive(ordinal:
> activeMacDesktopOrdinal)`, so the adapter MUST have a section config AND
> `activeMacDesktopOrdinal = 1`. Model the fixture on the existing
> `adapterWithWebLensAndWorkspace()` in `SetLayoutModeLensTests.swift:261`
> (it has BOTH a `type="lens"` "Web" section and a `type="workspace"` section —
> the same-index-clear test needs the workspace side). That helper is `private`
> to `SetLayoutModeLensTests`, so either (a) replicate it in the new test file,
> or (b) promote it to `Fixtures.swift` and call it from both. Concretely it
> sets `cfg.macDesktopSectionConfigs = [1: [DesktopSection(type: .workspace, …),
> DesktopSection(type: .lens, label: "Web", match: "app=Web")]]` and
> `a.activeMacDesktopOrdinal = 1` BEFORE any `activateSection` call. The
> `testCurrentActiveSectionDefaultsToWorkspaceOne` test needs no section config
> (it asserts the `.workspace(1)` default) and stays red-on-regression regardless.

- [ ] **Step 2: Run to verify it fails** — `swift build` FAIL ("no member 'activateSection'/'currentActiveSection'").

- [ ] **Step 3: Add protocol decls** in `Backend.swift` (after `setSectionLens` ~line 234):

```swift
/// Activate a section (EX-1 throughline) — a workspace (clears any active
/// lens, exclusive model) or a `type="lens"` section (cross-workspace
/// union). Lens-activate and workspace-activate funnel through this one
/// seam so the "exactly one active section" invariant has a single home
/// (grid/rail clicks join in EX-2; the user-facing CLI collapses to it in
/// EX-4). A lens *clear* stays on `setSectionLens(nil)` — clearing returns
/// to the active workspace without switching it. `autoFocus` follows
/// `setSectionLens`/`switchWorkspace`.
func activateSection(_ section: ActiveSection, autoFocus: Bool)
```

and (after `currentSectionLens` ~line 510):

```swift
/// The active section (EX-1) — `.lens(label)` when a section-lens is
/// active, else `.workspace(activeIndex)`. The unified, main-actor-safe
/// read-back the Controller mirrors for the single active-section
/// highlight; supersedes `currentSectionLens()` (now a `.lensLabel` shim).
/// Lock-guarded mirror of the active catalog's `activeSection`.
func currentActiveSection() -> ActiveSection
```

- [ ] **Step 4: Add extension defaults** in `Backend.swift` (`public extension WindowBackend`, near :585 / :628):

```swift
func activateSection(_ section: ActiveSection, autoFocus: Bool) {}
func currentActiveSection() -> ActiveSection { .workspace(1) }
```

- [ ] **Step 5: Consolidate the NativeAdapter mirror** (replace `_activeSectionLensLabel` block ~278-291):

```swift
private let sectionLensLock = NSLock()
/// Lock-guarded, main-readable mirror of the active catalog's `activeSection`
/// (EX-1: was a lens-only `String?`). The catalog is `cliQueue`-confined; the
/// Controller's `apply()` (main actor) reads this back to drive the single
/// active-section highlight — including after a mac-desktop swap restores a
/// desktop whose lens persists. Refreshed on `cliQueue` (every `refreshCatalog`
/// + each `setSectionLens`/`switchWorkspace`) under the lock so the main-thread
/// reads are race-free (same pattern as `config`).
private var _activeSection: ActiveSection = .workspace(1)

/// Refresh the main-readable mirror from the active catalog. Called on
/// `cliQueue` wherever `catalog.activeSection` may have changed.
func syncSectionLensMirror() {
    sectionLensLock.lock(); defer { sectionLensLock.unlock() }
    _activeSection = catalog.activeSection
}

public func currentActiveSection() -> ActiveSection {
    sectionLensLock.lock(); defer { sectionLensLock.unlock() }
    return _activeSection
}

/// Lens-only shim over `currentActiveSection()` for existing callers.
public func currentSectionLens() -> String? { currentActiveSection().lensLabel }
```

(Grep for any remaining `_activeSectionLensLabel` references and remove them — the consolidation must leave no orphan.)

> ⚠️ BUILD ORDER: `catalog.activeSection` is the computed property added in
> EX-1.1 — **EX-1.1 must already be committed on this branch before EX-1.2
> compiles**. The task order (1.1 → 1.2) is correct; do not reorder.
>
> ℹ️ SESSION RESTORATION (decision ⑭, "mac desktop 毎に最後のアクティブ section を
> session 保持"): the per-mac-desktop lens restore works because
> `syncSectionLensMirror()` is called in `refreshCatalog` (NativeAdapter+Queries.swift:151)
> AFTER `swapCatalogIfMacDesktopChanged` — so the swapped-in catalog's
> `activeSection` is mirrored before the Controller's `apply()` `macDesktopSwapped`
> read-back fires. Do NOT remove that `syncSectionLensMirror()` call; the
> consolidated `_activeSection` mirror depends on it for swap restoration.

- [ ] **Step 6: Implement `activateSection`** on `NativeAdapter` (near `switchWorkspace`):

```swift
public func activateSection(_ section: ActiveSection, autoFocus: Bool) {
    dispatchPrecondition(condition: .onQueue(cliQueue))
    switch section {
    case .workspace(let n):
        // Exclusive model: activating a workspace clears any active lens.
        // `setActive(activeIndex)` is a no-op (guards `n1Based != activeIndex`)
        // so `switchWorkspace(sameIndex)` would NOT clear the lens — clear it
        // explicitly when the target IS the current workspace but a lens is set.
        if catalog.activeSectionLens != nil && n == catalog.activeIndex {
            setSectionLens(nil, autoFocus: autoFocus)
        } else {
            switchWorkspace(toIndex: n - 1, autoFocus: autoFocus)   // 1-based → 0-based
        }
    case .lens(let label):
        setSectionLens(label, autoFocus: autoFocus)
    }
}
```

(Both branches route through existing methods that already call `syncSectionLensMirror()`, so the mirror stays current with no extra sync.)

- [ ] **Step 7: Run to verify EX-1.2 tests pass** — `swift build` clean; (CI) `ActiveSectionAdapterTests` green. Confirm no other call site referenced `_activeSectionLensLabel`.

- [ ] **Step 8: Commit**

```bash
git add Sources/FacetCore/Backend.swift \
        Sources/FacetAdapterNative/NativeAdapter.swift \
        Tests/FacetAdapterNativeTests/ActiveSectionAdapterTests.swift
git commit -m ":sparkles: feat(adapter): currentActiveSection mirror + activateSection throughline (EX-1.2)"
```

---

## Task EX-1.3: Controller authority — `currentActiveSection` replaces the double-SSOT mirror

**Files:**
- Modify: `Sources/FacetApp/Controller.swift` (field `currentActiveLens`:125 + comment; apply() read-back ~849-859; tree render `activeLens` ~983; new `activeWSIndex(in:)` helper; `reloadConfig` clear ~469-471)
- Modify: `Sources/FacetApp/Controller+CLIDispatch.swift` (`setActiveLens`:523-562; `dispatchWorkspace`; new `activateSection(_:)` Controller method)
- Modify: `Sources/FacetApp/Controller+ActiveMode.swift` (`toggleActiveLens`:303-307)
- Test: none — `FacetApp`/Controller has no XCTest harness (CI-only / host-verified posture, per EX-0.5). Guarded by `swift build` + the EX-1 host-verify. Review must scrutinize the double-SSOT resolution closely.

**Interfaces:**
- Consumes: `backend.activateSection(_:autoFocus:)`, `backend.currentActiveSection()` (EX-1.2), `ActiveSection` (EX-1.1).
- Produces: `Controller.currentActiveSection: ActiveSection`; `Controller.activateSection(_:autoFocus:)`.

- [ ] **Step 1: Add the `activeWSIndex` helper** on `Controller` (used by every clear/fallback path to know the spatial workspace when no lens is active):

```swift
/// The **1-based** index of the active workspace from the latest snapshot, or 1.
/// ⚠️ `Workspace.index` is **0-based** (snapshot seam: `index: entry.index - 1`,
/// WorkspaceCatalog.swift:823) while `ActiveSection.workspace` is 1-based
/// (Decision #6) — convert with `+ 1`. The `?? 0` only fires on an empty
/// snapshot. NOTE: the catalog's own `activeIndex` is ALREADY 1-based and maps
/// to the enum directly; only the `[Workspace]` snapshot needs this boundary +1.
func activeWSIndex(in wss: [Workspace]) -> Int {
    (wss.first(where: { $0.isActive })?.index ?? 0) + 1
}
```

> ⚠️ This off-by-one is the single highest-impact trap in this plan: without the
> `+ 1`, WS1-active mirrors `.workspace(0)` on every `apply()` read-back, every
> lens clear, and `reloadConfig` — silently corrupting the highlight + the
> idempotent guard. Verified: `Workspace.index = entry.index - 1` at
> WorkspaceCatalog.swift:823.

- [ ] **Step 2: Replace the field** — `var currentActiveLens: String?` → `var currentActiveSection: ActiveSection = .workspace(1)` (Controller.swift ~125). Rewrite the doc comment to describe the unified concept (it is the VIEW's optimistic mirror of `backend.currentActiveSection()` — the catalog authority; `.lens(label)` lights that lens header, `.workspace(N)` lights that workspace section; resolves the EX-0.5 double-SSOT by carrying the workspace index too, so `.workspace(N) != .lens(label)` can never stale-swallow a re-activation).

- [ ] **Step 3: Rewrite the apply() read-back** (Controller.swift ~853-859). Keep the EX-0.5 blip-resistant TRIGGER (`macDesktopSwapped`/`wsSwitched` computation + baseline-advance) exactly as-is; change only the VALUE:

```swift
if macDesktopSwapped || wsSwitched {
    if let ord = macDesktopOrdinal, !config.isSectionModelActive(ordinal: ord) {
        currentActiveSection = .workspace(activeWSIndex(in: wss)) // no section model → spatial
    } else {
        currentActiveSection = backend.currentActiveSection()     // the authority
    }
}
```

- [ ] **Step 4: Update the tree render call** (Controller.swift ~983): pass `activeLens: currentActiveSection.lensLabel` instead of `activeLens: currentActiveLens`.

- [ ] **Step 5: Rewire `setActiveLens`** (Controller+CLIDispatch.swift:523-562):
  - Clear branch (`label == nil`): guard on `if case .lens = currentActiveSection`; set `currentActiveSection = .workspace(activeWSIndex(in: lastWorkspaces))`; keep `runBackendCommand { bk.setSectionLens(nil, autoFocus:); return nil }`; `apply(lastWorkspaces)`.
  - Activate branch: idempotent guard `guard currentActiveSection != .lens(label) else { return }`; set `currentActiveSection = .lens(label)`; keep the `hasRenderedMacDesktop`/`lastRenderedMacDesktopOrdinal` swap-detector sync (lines 556-557, unchanged); change the backend call to the throughline `runBackendCommand { bk.activateSection(.lens(label), autoFocus:); return nil }`; `apply(lastWorkspaces)`. (Validation — `isSectionModelActive`, `lensSectionLabels` — unchanged.)

- [ ] **Step 6: Rewire `dispatchWorkspace(_ n:)`** (Controller+CLIDispatch.swift:578-595) — **one-line change only**. Keep the P6-atomic range check + the `"workspace N out of range (1..M)"` error string + the `runBackendCommand` wrapper EXACTLY as-is (verified: the range check reads `workspaces()` and the switch mutates it — both must stay in one `cliQueue` block). Change only the backend call inside the closure:

```swift
private func dispatchWorkspace(_ n: Int) {
    // P6: the range check reads `workspaces()` … and the switch mutates it —
    // both must happen in ONE cliQueue block (unchanged).
    runBackendCommand { bk in
        let count = bk.workspaces().count
        guard n >= 1, n <= count else {
            let hint = count > 0 ? "1..\(count)" : "no workspaces available"
            return "workspace \(n) out of range (\(hint))"
        }
        bk.activateSection(.workspace(n), autoFocus: true)   // ← was bk.switchWorkspace(toIndex: n - 1, …)
        return nil
    }
}
```

> Do **NOT** add an optimistic `currentActiveSection` set here. Workspace
> activation is NOT optimistic in EX-1 (declared deferred above): the lens
> darkens / the new workspace lights via the `apply()` read-back on the
> reconcile (`wsSwitched` → `currentActiveSection = backend.currentActiveSection()`),
> ~one reconcile later. Setting the main-actor field from inside the `cliQueue`
> closure would be a data race, and pre-setting before validation would re-introduce
> the stale-`.workspace(0)`/out-of-range mirror the original range check prevents.
> `n` is the 1-based ordinal `dispatchWorkspaceTarget` already resolved (it
> previously called `switchWorkspace(toIndex: n - 1)` — same 1-based input).
> The keyword/relative paths (`dispatchWorkspaceRelative` → `switchWorkspaceRelative`)
> are unchanged and out of EX-1 scope (deferred list).

- [ ] **Step 7: Add the `activateSection(_:)` Controller method** (Controller+CLIDispatch.swift) — the single Controller-side entry that the CLI dispatch and (future) views call; it preserves each path's validation by delegating:

```swift
/// Controller-side activation throughline (EX-1). Routes to the validated
/// per-kind entry: lens → `setActiveLens` (label lookup, idempotent guard,
/// section-model gate); workspace → `dispatchWorkspace` (range + optimistic
/// mirror). Both ultimately call `backend.activateSection`.
func activateSection(_ section: ActiveSection, autoFocus: Bool = true) {
    switch section {
    case .lens(let label):  setActiveLens(label, autoFocus: autoFocus)
    case .workspace(let n): dispatchWorkspace(n)
    }
}
```

- [ ] **Step 8: Reimplement `toggleActiveLens`** (Controller+ActiveMode.swift:303-307) over the new field (tree lens-header click keeps key → `autoFocus: false`):

```swift
func toggleActiveLens(_ label: String) {
    if currentActiveSection == .lens(label) {
        setActiveLens(nil)                              // toggle off → active workspace
    } else {
        activateSection(.lens(label), autoFocus: false) // tree keeps key focus
    }
}
```

- [ ] **Step 9: Update `reloadConfig` stale-lens clear** (Controller.swift ~469-471):

```swift
if case .lens(let l) = currentActiveSection, !lenses.contains(l) {
    currentActiveSection = .workspace(activeWSIndex(in: lastWorkspaces))
}
```

- [ ] **Step 10: Grep for any remaining `currentActiveLens` reference** across `Sources/FacetApp/` — every read site must be migrated (`.lensLabel` for label reads, `case .lens` for presence checks). Leave **zero** `currentActiveLens` occurrences. Audit each expected site (re-locate by symbol) and tick it:
  - field decl (Controller.swift ~125) → renamed to `currentActiveSection` (Step 2).
  - apply() read-back (~853-859) → Step 3.
  - tree render `activeLens:` (~983) → Step 4 (`.lensLabel`).
  - `setActiveLens` both branches → Step 5.
  - `dispatchWorkspace` → Step 6 (no direct read; throughline swap only).
  - `toggleActiveLens` → Step 8.
  - `reloadConfig` (~469-471) → Step 9.
  - ✅ **`revealLensParked` (Controller.swift ~1176)** — calls `setActiveLens(nil)`; it has NO direct field read, BUT it depends on the new `setActiveLens` clear branch guarding `if case .lens = currentActiveSection` (Step 5) before enqueuing the backend clear. Confirm Step 5's clear-branch guard is in place; this is the only migration risk on this path. Mark explicitly audited so the whole-branch review treats it as covered.

- [ ] **Step 11: Build gate** — `swift build` clean. (No unit tests; correctness is established by the EX-1.2 adapter tests + the host-verify in EX-1 host-verify.)

- [ ] **Step 12: Commit**

```bash
git add Sources/FacetApp/Controller.swift \
        Sources/FacetApp/Controller+CLIDispatch.swift \
        Sources/FacetApp/Controller+ActiveMode.swift
git commit -m ":recycle: refactor(controller): currentActiveSection authority — resolve double-SSOT (EX-1.3)"
```

---

## Task EX-1.4: Tree single-highlight + workspace-header via the throughline

**Files:**
- Modify: `Sources/FacetViewTree/SidebarView.swift` (`headerActive` 569-572)
- Modify: `Sources/FacetViewTree/SidebarView+Drag.swift` (`handleClick` workspace-header branch ~393-412)
- Test: none (view layer, host-verified). Build gate + EX-1 host-verify.

**Interfaces:**
- Consumes: `activeLens` param (now fed `currentActiveSection.lensLabel` by EX-1.3); `bk.activateSection(_:autoFocus:)` (EX-1.2).

- [ ] **Step 1: Fix the double-highlight** — `headerActive` (SidebarView.swift:569-572). Add the `activeLens == nil` exclusivity gate to the workspace branch:

```swift
func headerActive(_ sec: ProjectedSection) -> Bool {
    sec.sectionType == .lens
        ? (activeLens != nil && sec.label == activeLens)
        : (activeLens == nil && wsActive(sec.sourceWorkspaceIndex))  // ← lens active ⇒ ws dark
}
```

(When a lens is active, every workspace section header returns `false` → `Cell.hot=false` → `draw()` uses `pal.muted`. The catalog is already exclusive; the view now reflects it. No snapshot-contract change.)

- [ ] **Step 2: Route the workspace-header click through the throughline** — `SidebarView+Drag.handleClick` workspace-header branch (~line 411). Change `bk.switchWorkspace(toIndex: i, autoFocus: true)` → `bk.activateSection(.workspace(i + 1), autoFocus: true)`, with an inline comment `// ws.index is 0-based (snapshot seam); ActiveSection.workspace is 1-based`. **`i` is provably 0-based** — verified at the same handler: `lastWorkspaces.first { $0.index == i }` and `setOptimistic(workspaceIndex: i)` both match `i` against `Workspace.index`, which is `entry.index - 1` (0-based, WorkspaceCatalog.swift:823); the existing `switchWorkspace(toIndex: i)` takes 0-based too. So `i + 1` is the ONLY correct conversion (no "maybe pass directly" branch — passing `i` ships a WS1-click-activates-WS2 off-by-one). Keep the `cliQueue.async` dispatch and the preceding `exitActive(restore: false)` (#66 key-handback) exactly as-is. This also makes clicking the home workspace header while a lens is active clear the lens (via the EX-1.2 same-index-clear edge).

- [ ] **Step 3: Build gate** — `swift build` clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/FacetViewTree/SidebarView.swift Sources/FacetViewTree/SidebarView+Drag.swift
git commit -m ":sparkles: feat(tree): single active-section highlight + activateSection click (EX-1.4)"
```

---

## Task EX-1.5: Doc surface — config.toml + Spec/schema + glossary + architecture + README (EN/JA)

**Files:** `config.toml`, `Sources/FacetCore/FacetConfig+Spec.swift`, `config.schema.json`, `docs/glossary.md`, `docs/architecture.md`, `README.md`, `README.ja.md`. No code-behavior change; build gate covers the Spec edit + schema regen.

- [ ] **Step 1: config.toml — cross-WS exclusive wording + lens `layout` key.** Re-locate by content (line numbers are approximate):
  - Intro paragraph (~583-588): replace "anchor-parks the windows OUTSIDE it within the active workspace" → "anchor-parks every non-matching window in **every** workspace (cross-workspace exclusive — a real hide); switching to any workspace clears the lens; `--clear` lifts it and restores all parked windows."
  - `type="lens"` doc block (~619-621): replace "anchor-parks every window in the active workspace that the lens does NOT match … and re-tiles the rest" → "anchor-parks every non-matching window across **all** workspaces (cross-workspace exclusive hide) and union-tiles the matching set using this lens's `layout`; switching to any workspace clears the lens automatically."
  - In the `type="lens"` Keys block (~622-635), add `layout` after `match`: `# layout — (optional) the stateless tiling engine for the cross-workspace union while this lens is active: spiral (default) / master-left / master-right / master-top / master-bottom / master-center / grid / float. bsp and stack need per-workspace state a union can't keep → silently clamped to the global [layout] default. Omit → uses [layout] default.`
  - In the ACTIVE SAMPLE Web lens entry (~666), add a `layout = "spiral"` example line; leave Code/Chat without it (shows it's optional).
  - Remove/repair the stale hedge "the parallel `[grouping] by=tag` mode … is folded into it in a later phase" if present in the intro.

- [ ] **Step 2: FacetConfig+Spec.swift — lens `layout` in the schema spec.** Add a `layout` field entry to the `type="lens"` `[[desktop.N.section]]` description in the declarative `configSpec` (mirror the workspace `layout` entry; note "stateless engine name; clamps to [layout] default"). This keeps taplo/Even-Better-TOML completion in sync.

- [ ] **Step 3: Regenerate the schema** — the exact flag is `--emit-schema` (Main.swift:507): `.build/debug/facet --emit-schema > config.schema.json` (debug or release build). **Expected diff is `doc`-text-only, not a new JSON property:** the generator treats `[[desktop.N.section]]` as a `dynamicTable` without per-key typing (FacetConfig+Spec.swift ~171-186 — the `desktop` entry carries a single free-text `doc` string), so adding `layout` to the Spec updates that `doc` string, not the JSON Schema property set. Verify `git diff config.schema.json` shows only `doc` text changes (or nothing if the generator omits the desktop doc). Do NOT expect a new `layout` property — a smaller-than-expected diff is correct.

- [ ] **Step 4: docs/glossary.md.**
  - `### 4 つの中核概念` table (~141): broaden the `lens` row to note the dual meaning (tag-mode bitmask **and** section-model cross-WS exclusive filter, sharing the `facet lens` verb, never both active); add an `active section` row (the heading "4 つ" → "5 つ" + the surrounding "この … 綴り分ける" prose).
  - `### lens` entry (~200-227): append a clearly-labelled section-model paragraph cross-referencing `### active section`; keep the tag-mode definition.
  - `### active lens` entry (~708-742): update the hide effect from active-WS to **all-workspace** (cross-workspace exclusive); add `activateSection` / `currentActiveSection` to the code list.
  - NEW `### active section` entry: define `activeSection := activeLens (type=lens) XOR activeWorkspace`; exactly one active; lens activation clears the workspace highlight + parks non-matching windows across all workspaces (union); workspace activation clears the lens; startup = first `type=workspace` section. Code: `ActiveSection` / `WorkspaceCatalog.activeSection` / `WindowBackend.activateSection` / `currentActiveSection()`. Don't-call-it: active filter / selected section / "lens + workspace together" (they are mutually exclusive).

- [ ] **Step 4 (cont.): docs/architecture.md.**
  - "Section / lens read-path" "Where it is consumed" (~539-541): "in the active workspace" → "across **all** workspaces (cross-workspace exclusive)".
  - Add a sub-section "Two tiling machineries, one active section" with the table: `type=workspace` → stateful `applyLayout` on `activeIndex`, per-WS members, per-WS `layoutMode`; `type=lens` → stateless `sectionLensUnionFrames(layout:in:)`, cross-WS `sectionLensUnionMembers()`, lens `layout` (stateless only; bsp/stack clamp). Note: `ActiveSection` selects the machinery (`activeSectionLens != nil` → lens; else workspace); the catalog enforces the XOR.
  - Phase α Startup bullet (~192-194): note "the first `type=workspace` section (or WS index 1 with no section config) is the initial active section; no windows move on startup."

- [ ] **Step 5: README.md + README.ja.md (bilingual, same commit).** Update the `[[desktop.N.section]]` lens sub-description and the CLI cheatsheet Lens comment block in BOTH files from "within the active workspace" → "across **every** workspace (cross-workspace exclusive); switching any workspace clears the lens" (JA: 「すべての workspace で…cross-workspace exclusive に anchor park…workspace 切替で自動解除」). Verify the JA reads naturally (not a literal translation).

- [ ] **Step 6: Build gate** — `swift build` clean (Spec edit compiles); `git diff --stat` shows only docs + schema + Spec.

- [ ] **Step 7: Commit**

```bash
git add config.toml Sources/FacetCore/FacetConfig+Spec.swift config.schema.json \
        docs/glossary.md docs/architecture.md README.md README.ja.md
git commit -m ":memo: docs: cross-WS exclusive lens + active-section term + lens layout key (EX-1.5)"
```

---

## EX-1 host-verify (トミー operates; synthetic input NG)

After all five sub-tasks + the whole-branch review, ONE host-verify. トミー drives; the agent provides exact commands + expected `/tmp/facet.log` lines (per [[verification-commands-explicit]] / [[claude-driven-testing-protocol]] / [[feedback-no-input-injection-while-active]]). Requires AX granted (a source rebuild can drop the self-signed grant → re-toggle facet in System Settings ▸ Accessibility). Works only on a mac desktop whose ordinal has a `[[desktop.N.section]]` block (ordinal 1 in the ACTIVE SAMPLE).

1. **Build + run:** `./run.sh`. Confirm adoption: `.build/release/facet query` shows windows>0 (not all `gate=defer(unresolved)`).
2. **Startup invariant:** with `default-view = "tree"`, the panel shows the **first workspace** lit, **no** lens highlight, at boot.
3. **Single-highlight:** open Chrome on facet WS1 and WS2 (same mac desktop). `.build/release/facet lens "Web"` → tree lights **only** the `Web` lens header; **no** workspace header is lit (the EX-1.4 fix). `/tmp/facet.log`: `setSectionLens "Web" visible=N parked=M` (N≥2 = genuine cross-WS gather still works).
4. **Throughline + EX-0.5 stays fixed:** `lens "Web"` → `workspace --focus 2` (lens clears; WS2 lit, windows restore to home) → `workspace --focus 1` → `lens "Web"` **again** → re-activates (log shows a fresh `setSectionLens "Web" visible=N` + `section-lens autoFocus`); NOT a silent no-op. Then `facet lens --clear` → all parked windows restore.
5. **Same-index clear:** with `lens "Web"` active and WS1 the home workspace, click the **WS1 workspace header** in the tree → the lens clears (windows restore; WS1 lit). (Exercises the EX-1.2 same-index-clear edge.)
6. **Lens `layout` key:** set `layout = "spiral"` on the `Web` lens in `~/.config/facet/config.toml`, reload, `lens "Web"` → the union tiles with spiral geometry (`facet query --windows` frames match a spiral, not the global default). Set `layout = "bsp"` → clamps to the default (no crash, loud-silent clamp).

Provide before-each-step copy-paste commands + the exact expected log substring + "if it fails, send /tmp/facet.log lines matching `section-lens`/`setSectionLens`/`switchWorkspace`".

---

## Whole-branch review (before host-verify)

After EX-1.5, run the strongest-model whole-branch review over `main..feat/ex1-active-section` (Ultra, 3 adversarial lenses + adjudication): correctness (does the SSOT resolution actually eliminate the stale-swallow? are all `currentActiveLens` sites migrated? does the same-index-clear edge hold?), layer-spine (ActiveSection stays pure FacetCore; no adapter type leaks to views), regression-scope (no behavior change in the by-workspace / tag-mode paths; `currentSectionLens()` shim byte-equivalent for existing callers). Triage findings; fix-first before host-verify.

---

## Self-Review (run after writing; fix inline)

**Spec coverage** (EX-1 row = "Exactly one lit active-section highlight; ActiveSection authority + activateSection verb (throughline); config/docs/glossary; startup/session-active wired"):
- ✅ ActiveSection authority → EX-1.1 (enum + catalog) + EX-1.2 (adapter mirror) + EX-1.3 (Controller field).
- ✅ activateSection throughline → EX-1.2 (backend seam) + EX-1.3 (Controller method + CLI wiring) + EX-1.4 (tree click).
- ✅ Exactly one lit highlight → EX-1.4 (tree `headerActive` gate). ⚠️ grid/rail explicitly DEFERRED to EX-2 (documented above — not a silent gap).
- ✅ config/docs/glossary → EX-1.5.
- ✅ startup/session-active → EX-1.1 (test + invariant) + EX-1.3 (read-back covers per-mac-desktop session lens via `currentActiveSection()`). No boot code needed (zero-value default is correct).
- ✅ double-SSOT resolution (EX-0.5 follow-through) → EX-1.3 (typed field + structural idempotent guard).

**Placeholder scan:** none — every code step shows actual Swift. Line numbers flagged "re-locate by symbol".

**Type consistency:** `ActiveSection.workspace(Int)` is 1-based everywhere; the only 0-based conversion is `switchWorkspace(toIndex: n-1)` inside `NativeAdapter.activateSection` and `bk.activateSection(.workspace(i+1))` in the tree (where `i` is the 0-based row index — verify at the call site). `currentActiveSection` (Controller field) / `currentActiveSection()` (backend method) names are distinct (field vs func) and consistent. `lensLabel` helper used identically in the shim + tree render.

**Adversarial review applied (wf `994dc5ea`, 3 lenses + opus adjudication):** 5 must-fixes + 4 should-fixes folded in — M1 `activeWSIndex` off-by-one (`+ 1`; `Workspace.index` is 0-based), M2 `dispatchWorkspace` keeps the P6 range check (one-line swap only), M3 `WorkspaceConfig(name: "")`/`seededCatalog(2)`, M4 lens fixture sets `activeMacDesktopOrdinal = 1` (`adapterWithWebLensAndWorkspace`), M5 `i + 1` definitive (no hedge); S1 `--emit-schema` doc-only diff, S2 EX-1.1→1.2 build order, S3 `revealLensParked` audited, S4 `updateConfig` auto-clear declared deferred. **Verdict after fixes: execution-ready.**

**Highest trap to watch in execution:** M1 — the `+ 1` in `activeWSIndex`. Two of three review lenses missed it; without it the mirror reads `.workspace(0)` on the most common path and quietly breaks the idempotent guard. The catalog's `activeIndex` is 1-based (maps to the enum directly); only the `[Workspace]` snapshot crosses the 0-based boundary.
