# EX-4 — Tag-mode removal + tag-storage migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the legacy `[grouping] by="tag"` tag mode entirely (the M11-3 feature subsumed by the exclusive section model), migrate the surviving window-tag storage from a UInt64 bitmask to `Set<String>`, lift the grid/rail tag-mode `exit 2`, collapse the CLI to two systems, and pin startup = first `type="workspace"` section — the FINAL stage of the exclusive-selection model (EX-0…EX-4).

**Architecture:** EX-0…EX-3 (all shipped, main `73b3500`) built an `ActiveSection` model — exactly one section (`type="workspace"` XOR `type="lens"`) active at a time, with cross-workspace union tiling via `LensMembership` string-match predicates. The legacy "tag mode" (a UInt64-bitmask lens over a global tag vocabulary, `[grouping] by="tag"`) is now redundant: every tag-mode capability has a section-model twin (`type="lens"` + `match='tag~=X'`). EX-4 removes tag mode and re-represents the one surviving concept — **per-window tags as a free-form attribute** (used by lens `tag~=X` matching + `window --tag`) — as `Set<String>` instead of a bit in a registry.

**Tech Stack:** Swift 6, macOS 13+, 3 layers (`FacetCore` pure / `FacetAdapterNative` backend / `FacetView*`+`FacetApp` GUI). Build gate = `swift build` (CLT-local); XCTest runs CI-only (`feedback-swift-tests-only-compile-in-ci`).

## Global Constraints

- **Layer spine is non-negotiable.** `FacetCore` stays pure (CoreGraphics OK, no AppKit/AX/backend). Tag storage lives in the adapter (`WorkspaceCatalog.WindowSlot`); the `FacetCore` `Window.tags` display field is the only tag type crossing to views.
- **Breaking changes are fine** (個人開発 / no-backward-compat — `design-principles`). No deprecation stubs, no compat shims, no auto-migration tool. Pure delete.
- **Each commit must `swift build` green.** Swift won't compile a half-deleted symbol graph — order deletions callers→impl→types.
- **Tests are CI-only.** Write them defensively (CLT can't run XCTest). A Spec/schema edit MUST regenerate `config.schema.json` (`facet --emit-schema`) + sweep contradicting tests in the SAME commit (EX-3 CI lesson, ledger).
- **Config never rejects unknown keys** — it clamps to defaults (`config-default-behavior`). A leftover `[grouping]`/`[[tag]]` in a user's config is silently ignored, never a crash.
- **Commit convention:** gitmoji + Conventional (`<:gitmoji:> <type>(<scope>)<!>: <subject>`). This is a breaking refactor → `:boom: feat(...)!:` / `:fire: refactor(...)!:`.
- **No push/merge without explicit トミー go** (`pr-conventions` / `grid-view-work-style`). Host-verify is トミー-operated (synthetic input NG, fresh consent each screen-moving op).

## The decision (トミー-blessed, 2026-06-22)

`AskUserQuestion` → **"全部削除・2系統化 (推奨)"**. Drop the runtime tag/lens composition CLI built in #176/#191 entirely; the exclusive model leaves only two CLI systems.

- **Deleted:** `facet lens --add/--remove/--toggle/--all` (dynamic multi-tag union composition) + `facet tag --add/--remove/--rename` (tag-vocabulary management). No dynamic lens composition (canon ⑬ "later phase" — deferred, not built).
- **Kept (the 2 systems):** ① `facet lens NAME` / `facet lens --clear` (section activate/deactivate); ② `facet window --tag/--untag/--toggle-tag/--retag` (window attribute, ungated — always available).

## Claude-decided implementation choices (house-rule-obvious; トミー may veto at plan review)

- **`WindowSlot.tags: UInt64` → `Set<String>`** (canon "string set"; removes the 63-tag cap).
- **`Window.tags` (FacetCore display model) → `[String]` SORTED** at the overlay seam (deterministic `#tag` chip order; avoids a `Set`-iteration-order regression). `ApplyResolver`'s simulated tags stay ordered `[String]` for apply-parity.
- **`facet query --windows` `tags` field = KEEP** (load-bearing for host-verify `tags=['web']`; machine contract). Emit sorted.
- **Leftover `[grouping]`/`[[tag]]` keys = silently ignored** (house clamp rule) + repo `config.toml` template cleaned. No loud reject, no migration tool.
- **`Grouping` + `LayoutGrouping` enums = pure delete** (no `.workspace`-only stub).

## Sequencing constraints (from the codemap critic, `wf_d454538f-389`)

1. `WindowSlot.tags` UInt64→Set migration lands WITH its readers (bitmask ops fail on a Set) — that's EX-4.3, one coherent commit.
2. `Grouping` enum deletion only AFTER every `grouping == .tag` branch is gone — EX-4.2.
3. `LayoutGrouping` deletion is safe: the section-lens layout reject already uses `LensLayout.isStateless`, NOT `LayoutGrouping.isCompatible` (EX-0.3; verified `NativeAdapter+LayoutMode.swift:29` comment). All 6 `LayoutGrouping` references are `with: .tag` (verified grep) → no workspace-path dependency.
4. CLI gate-removal + verb-deletion land together (no orphaned parser branches).
5. Startup verification lands FIRST (critic #17 — a broken startup active-section hidden by tag mode would surface mid-refactor).

## File structure (what each task touches)

**DELETE outright:**
- `Sources/FacetCore/Grouping.swift` (whole file — `Grouping` enum + `LayoutGrouping`)
- `Sources/FacetCore/LensRoute.swift` (whole file — `routeLens` / `LensAction` / `LensEffect` / `LensRouteError`)
- `Sources/FacetCore/TagModel+LensFilter.swift` (whole file — bitmask→filter parity, dead path)
- `Sources/FacetCore/TagModel.swift` (whole file — UInt64 bit registry; deleted in EX-4.3 after window-attr ops switch to `Set<String>`)
- `Sources/FacetAdapterNative/WorkspaceCatalog+Tags.swift` (whole file — tag-mode grouping/lens machinery; its 4 surviving window-attribute mutators move to a new file in EX-4.2)
- `Tests/FacetCoreTests/TagModelTests.swift`, `Tests/FacetAdapterNativeTests/TagCatalogTests.swift`, and any `QueryTagsLensTests`/`LensRouteTests` (CI-only; deleted/rewritten with their code)

**CREATE:**
- `Sources/FacetAdapterNative/WorkspaceCatalog+WindowTags.swift` (the 4 surviving Set-based window-attribute mutators: `addTagToWindow` / `removeTagFromWindow` / `toggleTagOnWindow` / `retagWindow`)
- `Tests/FacetAdapterNativeTests/WindowTagsTests.swift` (Set-based attribute mutation parity)
- `Tests/FacetAdapterNativeTests/StartupActiveSectionTests.swift` (multi-section startup invariant) — or extend `SectionLensCatalogTests`

**MODIFY (delete tag branches / lift gates / migrate type):**
- `Sources/FacetCore/FacetConfig.swift` (`grouping`/`tagDefs` fields; `effectiveGrouping`/`effectiveTagModel`; `fatalConfigErrors` tag block; `effectiveMacDesktopSectionConfigs` tag clamp)
- `Sources/FacetCore/FacetConfig+Decode.swift` (`tagDefs` parse + tag-mode warning)
- `Sources/FacetCore/FacetConfig+Spec.swift` (`by` enum + `[[tag]]` shape)
- `Sources/FacetCore/Models.swift` (`Window.tags` type/doc)
- `Sources/FacetCore/ApplyResolver.swift` (`ApplyPlanWindowFields.tags` simulation)
- `Sources/FacetCore/Backend.swift` (`setLens` protocol method delete; window-tag method signatures)
- `Sources/FacetAdapterNative/WorkspaceCatalog.swift` (`WindowSlot.tags` type; `grouping`/`tagModel`/`lens`/`tagLayoutMode`/`effectiveTagLayout` state; `snapshot()` tag branch :789; `makeWindow` overlay :897-899)
- `Sources/FacetAdapterNative/NativeAdapter.swift` (`setLens` :639-689; tag-union comment :669)
- `Sources/FacetAdapterNative/NativeAdapter+Tagging.swift` (lift `tagVocabReady` gate; drop park/restore from settle; delete `addTag`/`removeTag`/`renameTag` vocab verbs)
- `Sources/FacetAdapterNative/NativeAdapter+Queries.swift` (tag seed :289; `parkOutOfLensWindows` :389; overlay :490)
- `Sources/FacetAdapterNative/NativeAdapter+QueryCommand.swift` (`currentLens` :49; overlay :151,168)
- `Sources/FacetAdapterNative/NativeAdapter+Scratchpad.swift` (applyLayout tag branch :532)
- `Sources/FacetAdapterNative/NativeAdapter+LayoutMode.swift` (setLayoutMode tag branch :44-61)
- `Sources/FacetAdapterNative/NativeAdapter+Slide.swift` (targetFrames tag branch :65)
- `Sources/FacetApp/Main.swift` (help text; `requireGrouping` :424; grid/rail exit-2 :656-667; `facet tag` dispatch :545)
- `Sources/FacetApp/FacetApp+ClientCommands.swift` (`runLensCommand` composition branches :110-208; `runTagCommand` :238-271; `runWindowCommand` gate :389)
- `Sources/FacetApp/Controller+CLIDispatch.swift` (tag-add/remove/rename DNC :194-225; `lens-section:`→`lens:` rename :65-81)
- `Sources/FacetView/ViewContextMenu.swift` + `Sources/FacetViewTree/SidebarView+Menus.swift` (layout-picker `LayoutGrouping…with: .tag` filter :120 / :52; `tagMode` param)
- docs: `config.toml`, `config.schema.json`, `docs/glossary.md`, `docs/architecture.md`, `README.md`, `README.ja.md`

**VERIFY-ONLY (must NOT regress — accidental-deletion risk):**
- `WorkspaceCatalog+SectionLens.swift` (applySectionLens, sectionLensUnionMembers/Frames, lensParkedMembers) — the whole EX-0…3 section machinery
- `NativeAdapter.swift:508` setActive section-lens gate (`activeSectionLens != nil && n == activeIndex`)
- `NativeAdapter+Queries.swift:154,423-433` `activeSectionLensApplyTags` (new-window inheritance, EX-3.3)
- `LensMembership.matches` / `FilterProjection` (tag~=X is STRING-based already — clean through migration)
- `ApplyResolver.inverse` (removeTag-only — strings, unchanged)
- `DesktopSection` `ApplyOp.addTag/removeTag` TOML parse (window-attribute apply — survives)
- marks (`markFocusedWindow`/`focusMark`/`unmark`) — window state, NOT tags

---

## Task EX-4.1: startup = first `type="workspace"` section (verify + harden)

Critic #17: verify startup BEFORE deleting tag mode. The startup-reader found canon ⑭ is ALREADY satisfied structurally (`WorkspaceCatalog.activeIndex` hardcoded `1`, no persistence). This task PINS that with a multi-section test and verifies the config filter, so any later regression is caught.

**Files:**
- Read/verify: `Sources/FacetCore/FacetConfig.swift` (`effectiveWorkspaceList` + `effectiveMacDesktopSectionConfigs`), `Sources/FacetAdapterNative/WorkspaceCatalog.swift:135,367,394,411`
- Test: `Tests/FacetAdapterNativeTests/StartupActiveSectionTests.swift` (new) or extend `SectionLensCatalogTests.swift:28`

**Interfaces:**
- Consumes: `WorkspaceCatalog.activeSection` (`= activeSectionLens.map(.lens) ?? .workspace(activeIndex)`), `WorkspaceCatalog.seed(configs:)`, `FacetConfig.effectiveWorkspaceList(forMacDesktopOrdinal:)`.
- Produces: a pinned guarantee that a catalog seeded from a config whose sections are `[lens, workspace "A", workspace "B"]` has `activeSection == .workspace(1)` pointing at the FIRST `type="workspace"` section ("A"), in section-array order.

- [ ] **Step 1: Read `FacetConfig.effectiveWorkspaceList` + `effectiveMacDesktopSectionConfigs`** and confirm: (a) it returns ONLY `type="workspace"` sections (drops `type="lens"`), (b) preserves section-array order (not raw config ordinal). Note the exact symbol names + line numbers in the task notes.

- [ ] **Step 2: Write the failing test** — seed a catalog from a config whose section order is lens-first, then two workspaces:

```swift
func testStartupActiveIsFirstWorkspaceSectionAcrossMultipleSections() {
    // sections in config order: a lens, then workspace "A", then workspace "B".
    let cfg = FacetConfig(/* desktop.1 sections = [lens "Web" match:"tag~=web", ws "A", ws "B"] */)
    var c = WorkspaceCatalog()
    c.seed(configs: cfg.effectiveWorkspaceList(forMacDesktopOrdinal: 1))
    // canon ⑭: startup active = FIRST type=workspace section, never the lens.
    XCTAssertEqual(c.activeSection, .workspace(1))
    XCTAssertEqual(c.workspaceNames.first, "A")   // first WORKSPACE section, not the lens
    XCTAssertNil(c.activeSectionLens)              // never a lens at startup
}
```

- [ ] **Step 3: Run the test (CI-only — locally confirm it COMPILES via `swift build`)**. Run: `swift build`. Expected: GREEN (test target compiles). If `effectiveWorkspaceList` already filters+orders correctly, the assertion is satisfied at CI; if NOT, fix the filter in `FacetConfig` (filter `type == .workspace`, keep section-array order) — that fix becomes part of this commit.

- [ ] **Step 4: If a fix was needed, re-confirm `swift build` green.** Otherwise skip.

- [ ] **Step 5: Commit.**

```bash
git checkout -b feat/ex4-tag-mode-removal
git add Tests/FacetAdapterNativeTests/StartupActiveSectionTests.swift Sources/FacetCore/FacetConfig.swift
git commit -m ":white_check_mark: test(catalog): pin startup active = first type=workspace section (EX-4.1)"
```

---

## Task EX-4.2: delete the by=tag GROUPING machinery (breaking)

Delete tag-mode grouping/lens everywhere, KEEPING `TagModel` + `WindowSlot.tags: UInt64` as the window-attribute store (auto-vivify bit registry) — that storage migrates in EX-4.3. After this task: `catalog.grouping`/`lens`/`tagLayoutMode` gone, no `grouping == .tag` branch anywhere, `facet tag` + `lens --add/...` gone, `window --tag` ungated + a pure attribute setter (no park/restore — section-lens reconcile owns visibility), grid/rail exit-2 gone. Order: **delete callers → delete impl → delete types**, each sub-step `swift build` green (commit at green points; 2–3 commits acceptable).

**Files:** see "MODIFY/DELETE" lists above (the FacetCore types, the adapter machinery, the CLI surface).

**Interfaces:**
- Consumes: `catalog.activeSectionLens`, `applySectionLensReconcile()`/`applySectionLens(...)` (EX-0 section park/restore), `activeDisplayRect()`, `applyLayout(workspace:rect:)`.
- Produces: `WorkspaceCatalog` with NO `grouping`/`lens`/`tagLayoutMode`/`tagModel`-seeding-of-mode; the 4 window-attribute mutators relocated to `WorkspaceCatalog+WindowTags.swift` (still UInt64, still via `tagModel.add`/`bit`); `NativeAdapter` window-tag verbs ungated + reconcile-driven.

### Step group A — delete the CLI callers (build-green commit)

- [ ] **A1: `FacetApp/FacetApp+ClientCommands.swift`** — in `runLensCommand` (≈:110-208) delete the `--add/--remove/--toggle/--all` branches; keep positional `NAME` (activate section) + `--clear`. Delete `runTagCommand` (≈:238-271) entirely. In `runWindowCommand` (≈:277-416) delete the `requireGrouping(.tag)` gate (≈:389) so `--tag/--untag/--toggle-tag/--retag` always parse.
- [ ] **A2: `FacetApp/Main.swift`** — delete `requireGrouping` (:424) + all callers; delete the `tag` subcommand dispatch (:545); delete the grid/rail `requireGrouping(.workspace)` exit-2 (:656-667); rewrite `printHelp` (:94-207) to drop the `tag`/composition lines + tag-mode caveats and reflect the 2-system surface.
- [ ] **A3: `FacetApp/Controller+CLIDispatch.swift`** — delete the `tag-add`/`tag-remove`/`tag-rename` DNC cases (:194-225); rename the DNC `lens-section:` → `lens:` and delete the tag-mode `lens:` path (:65-81). (Single wire-protocol rename — no compat alias, no old clients exist.)
- [ ] **A4: `FacetView/ViewContextMenu.swift` (:112-123,214-258) + `FacetViewTree/SidebarView+Menus.swift` (:52)** — delete the `LayoutGrouping.isCompatible(..., with: .tag)` layout-picker filter + the `tagMode` parameter; the layout picker now offers the workspace-compatible set unconditionally (workspace section) / `LensLayout`-stateless set (lens section, already handled).
- [ ] **A5: `swift build` green** (CLI no longer references composition/vocab verbs; backend `setLens`/vocab methods now dead but still present). Commit:

```bash
git commit -am ":fire: refactor(cli)!: drop facet tag + lens --add/--remove/--toggle/--all + tag-mode gates (EX-4.2a)"
```

### Step group B — delete the adapter tag-mode machinery (build-green commit)

- [ ] **B1: `NativeAdapter+Tagging.swift`** — delete `addTag(_:)` / `removeTag(_:)` / `renameTag(_:to:)` (vocab verbs, :196-251). In `tagVocabReady` (:181) drop `catalog.grouping == .tag`, keep `config.isMacDesktopManaged(...)`; rename to e.g. `windowTagReady`. In `settleWindowRetag` (:135-146) DELETE the `applyHide(toPark:/toRestore:)` park/restore block — instead call `applySectionLensReconcile()` (re-evaluate the active lens membership for the changed tag set) then `applyLayout(workspace:rect:)` + `refreshNeeded`. The catalog mutators still return `RetagVisibility`; ignore it here (reconcile owns visibility) — or change their return in B3.
- [ ] **B2: `NativeAdapter.swift`** — delete `setLens` (:639-689) + the tag-union comment (:669). `NativeAdapter+Scratchpad.swift` delete the `if catalog.grouping == .tag { applyFrames(tagUnionFrames…) }` branch (:532). `NativeAdapter+Slide.swift` delete the `if catalog.grouping == .tag { return tagUnionFrames }` branch (:65). `NativeAdapter+LayoutMode.swift` delete the whole `if catalog.grouping == .tag {…}` block (:44-61). `NativeAdapter+Queries.swift` delete the tag seed (:289 `if config.effectiveGrouping == .tag { seedTags(…) }`) + `parkOutOfLensWindows` (:389, tag-gated → delete or no-op). `NativeAdapter+QueryCommand.swift` delete `currentLens()` (:49) and its DNC/query wiring.
- [ ] **B3: split `WorkspaceCatalog+Tags.swift`** — CREATE `WorkspaceCatalog+WindowTags.swift` holding ONLY the surviving window-attribute mutators (`addTagToWindow` / `removeTagFromWindow` / `toggleTagOnWindow` / `retagWindow` / `addTagName` / `RetagVisibility` / `RetagOutcome` / `retagVisibility` helper) — UNCHANGED (still UInt64 + `tagModel`, migrated in EX-4.3). DELETE `WorkspaceCatalog+Tags.swift` (seedTags, tagsForNewWindow, visibleNonFloatingMembers, tagUnionFrames, tagSnapshot, lens resolvers `lensOnly/Added/Removed/Toggled/lensMaskStrict/lensAll`, removeTagName, renameTagName, setLens, LensPlan). In `WorkspaceCatalog.swift` delete state `grouping` (:154), `lens` (:162), `tagLayoutMode` (:196), `effectiveTagLayout` (:200) and the `snapshot()` tag branch (`if grouping == .tag { return tagSnapshot() }`, :789) — `snapshot()` always returns the workspace snapshot now. KEEP `tagModel` (:158) until EX-4.3 (window-attr ops still use it).
- [ ] **B4: `Backend.swift`** — delete the `setLens(_ spec: LensSpec)` protocol method (:216) + `LensSpec` if unused elsewhere. Keep window-tag protocol methods + `activateSection`.
- [ ] **B5: `swift build` green.** Commit:

```bash
git commit -am ":fire: refactor(adapter)!: delete tag-mode lens/grouping machinery; window --tag becomes a pure reconcile-driven attribute (EX-4.2b)"
```

### Step group C — delete the FacetCore types (build-green commit)

- [ ] **C1: `FacetCore/Grouping.swift`** — DELETE the file (`Grouping` enum + `LayoutGrouping`). Confirm no remaining reference (`grep -rn "Grouping" Sources/` → only comments, fix them).
- [ ] **C2: `FacetCore/LensRoute.swift`** — DELETE the file. Confirm `routeLens`/`LensAction`/`LensEffect`/`LensRouteError` have no callers (the CLI rewrite in A1 removed them).
- [ ] **C3: `FacetCore/TagModel+LensFilter.swift`** — DELETE the file (`lensFilter`, bitmask→filter parity, dead).
- [ ] **C4: `FacetConfig.swift`** — delete `grouping` (:186) + `tagDefs` (:190) raw fields; `effectiveGrouping` (:599) + `effectiveTagModel` (:608); the `fatalConfigErrors` tag block (:631-654, the `guard effectiveGrouping == .tag` + `LayoutGrouping`/`[[tag]]`/grid checks); the `effectiveMacDesktopSectionConfigs` tag clamp (:589, now always returns `macDesktopSectionConfigs`). `FacetConfig+Decode.swift` delete `tagDefs` parse (:155) + the tag-mode-ignores-sections warning (:159-167). `FacetConfig+Spec.swift` delete the `by` field (:61) + the `[[tag]]` shape.
- [ ] **C5: `swift build` green.** Confirm `grep -rn "grouping\|TagModel\|LensRoute\|LayoutGrouping\|tagDefs\|\.tag\b" Sources/FacetCore/` returns only intentional survivors (Window.tags, ApplyOp.addTag, tag~= filter field). Commit:

```bash
git commit -am ":fire: refactor(core)!: delete Grouping/LayoutGrouping/LensRoute/TagModel+LensFilter + [grouping]/[[tag]] config (EX-4.2c)"
```

---

## Task EX-4.3: migrate tag storage UInt64 → `Set<String>` (delete `TagModel`)

Now the only `TagModel`/UInt64 users are the 4 window-attribute mutators + the `makeWindow`/query overlay + `ApplyPlanWindowFields`. Migrate `WindowSlot.tags` to `Set<String>`, delete `TagModel`, and simplify the mutators (a `Set.insert` IS auto-vivify; no bits, no floor, no `RetagVisibility` — reconcile owns visibility).

**Files:**
- `Sources/FacetAdapterNative/WorkspaceCatalog.swift` (`WindowSlot.tags` :61 + init :62 + doc :53-61; `makeWindow` overlay :897-899; all `tags: slot.tags` re-creation sites carry forward unchanged)
- `Sources/FacetAdapterNative/WorkspaceCatalog+WindowTags.swift` (the 4 mutators, created in B3 — rewrite to Set ops)
- `Sources/FacetAdapterNative/NativeAdapter+Tagging.swift` (mutator return-type/wiring)
- `Sources/FacetAdapterNative/NativeAdapter+QueryCommand.swift` (overlay :151,168) + `NativeAdapter+Queries.swift` (overlay :490, `withTags`)
- `Sources/FacetCore/Models.swift` (`Window.tags` — keep `[String]`, sorted at the seam; update doc)
- `Sources/FacetCore/ApplyResolver.swift` (`ApplyPlanWindowFields.tags` :232-287 — stays ordered `[String]`)
- DELETE `Sources/FacetCore/TagModel.swift` + `Tests/FacetCoreTests/TagModelTests.swift`
- Test: `Tests/FacetAdapterNativeTests/WindowTagsTests.swift` (new); update/delete `TagCatalogTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `WindowSlot.tags: Set<String>` (default `[]`); `addTagToWindow(_:name:)`/`removeTagFromWindow(_:name:)`/`toggleTagOnWindow(_:name:)` returning `Bool` (mutated? — no `RetagVisibility`); `retagWindow(_:old:new:)` returning a small `Bool`/`enum`; `makeWindow` overlay = `populateTags ? (windowMap[w.id]?.tags).map { $0.sorted() } ?? [] : []`.

- [ ] **Step 1: Write the failing test** (`WindowTagsTests.swift`):

```swift
func testWindowTagsAreAFreeFormStringSet() {
    var c = seededCatalog(1)                 // one workspace, one tracked window id=10
    XCTAssertTrue(c.addTagToWindow(WindowID(serverID: 10), name: "web"))
    XCTAssertTrue(c.addTagToWindow(WindowID(serverID: 10), name: "code"))
    XCTAssertEqual(c.windowMap[WindowID(serverID: 10)]?.tags, ["web", "code"])  // Set<String>, no cap, no floor
    XCTAssertTrue(c.removeTagFromWindow(WindowID(serverID: 10), name: "web"))
    XCTAssertEqual(c.windowMap[WindowID(serverID: 10)]?.tags, ["code"])
    XCTAssertTrue(c.toggleTagOnWindow(WindowID(serverID: 10), name: "web"))     // re-adds
    XCTAssertEqual(c.windowMap[WindowID(serverID: 10)]?.tags, ["web", "code"])
}
func testNewTagNameAutoVivifiesWithNoVocabulary() {
    var c = seededCatalog(1)
    XCTAssertTrue(c.addTagToWindow(WindowID(serverID: 10), name: "brand-new-tag"))  // no TagModel, no 63-cap
    XCTAssertEqual(c.windowMap[WindowID(serverID: 10)]?.tags, ["brand-new-tag"])
}
```

- [ ] **Step 2: `swift build`** — expect FAIL (`addTagToWindow` still returns `RetagVisibility?`, `tags` still `UInt64`).

- [ ] **Step 3: Migrate `WindowSlot`** (`WorkspaceCatalog.swift:53-66`):

```swift
/// Free-form per-window tag set (EX-4). Used by lens `match='tag~=X'`
/// + `facet window --tag/--untag/--toggle-tag/--retag`. Session-only
/// (never persisted); empty until the user tags the window. Every
/// `WindowSlot` re-creation carries it forward (a Set copies trivially).
var tags: Set<String>
init(workspace: Int?, pid: Int, tags: Set<String> = []) {
    self.workspace = workspace
    self.pid = pid
    self.tags = tags
}
```

- [ ] **Step 4: Rewrite the 4 mutators** (`WorkspaceCatalog+WindowTags.swift`) to Set ops — no bit, no floor, no `RetagVisibility`/`RetagOutcome`/`TagModel`:

```swift
@discardableResult mutating func addTagToWindow(_ id: WindowID, name: String) -> Bool {
    guard var slot = windowMap[id] else { return false }
    slot.tags.insert(name); windowMap[id] = slot; return true
}
@discardableResult mutating func removeTagFromWindow(_ id: WindowID, name: String) -> Bool {
    guard var slot = windowMap[id], slot.tags.contains(name) else { return false }
    slot.tags.remove(name); windowMap[id] = slot; return true
}
@discardableResult mutating func toggleTagOnWindow(_ id: WindowID, name: String) -> Bool {
    guard var slot = windowMap[id] else { return false }
    if slot.tags.contains(name) { slot.tags.remove(name) } else { slot.tags.insert(name) }
    windowMap[id] = slot; return true
}
/// `facet window --retag OLD NEW` (#228): replace OLD with NEW (a no-op
/// on OLD if absent = a bare add of NEW). Returns false only if untracked.
@discardableResult mutating func retagWindow(_ id: WindowID, old: String, new: String) -> Bool {
    guard var slot = windowMap[id] else { return false }
    slot.tags.remove(old); slot.tags.insert(new); windowMap[id] = slot; return true
}
```

- [ ] **Step 5: Rewire `NativeAdapter+Tagging.swift`** — the `applyWindowRetag`/`retagFocusedWindow` handlers now take a `Bool`-returning mutator; on success call `applySectionLensReconcile()` (re-park/restore for the active lens) + `applyLayout(workspace: catalog.activeIndex, rect: activeDisplayRect())` + `eventContinuation.yield(.refreshNeeded)`. Map `retagWindow` `false` → the existing no-window error. (Auto-vivify + unknown-name are no longer reject paths — `Set` always succeeds for a tracked window; `--untag` of an absent tag returns `false` = "not present", surfaced as before.)

- [ ] **Step 6: Migrate the overlay seams** — `makeWindow` (`WorkspaceCatalog.swift:897-899`):

```swift
tags: populateTags ? (windowMap[w.id]?.tags.sorted() ?? []) : [],
```

`NativeAdapter+QueryCommand.swift:151,168` and `NativeAdapter+Queries.swift:490` (`withTags`): replace `cat.tagModel.names(in: slot.tags)` with `slot.tags.sorted()`.

- [ ] **Step 7: `ApplyResolver.swift` (`ApplyPlanWindowFields.tags`, :232-287)** — keep the simulated tags as ordered `[String]` applying `addTag`/`removeTag` ops; the post-orphan/section match invariant (EX-3) is unaffected (it reads names, never bits). Verify the apply-simulate compiles against `Window.tags: [String]` (unchanged FacetCore type).

- [ ] **Step 8: DELETE `TagModel.swift` + `TagModelTests.swift`.** `grep -rn "TagModel" Sources/ Tests/` → zero. Update/delete `TagCatalogTests.swift` (rewrite the surviving window-tag cases into `WindowTagsTests.swift`, delete the bit/lens/vocab cases).

- [ ] **Step 9: `swift build` green** + the new test compiles. Commit:

```bash
git commit -am ":boom: refactor(adapter)!: migrate window tags UInt64 bitmask → Set<String>; delete TagModel (EX-4.3)"
```

---

## Task EX-4.4: docs / config / schema / glossary / README + stale-test sweep + schema regen

EX-3 CI lesson: a Spec edit MUST regenerate `config.schema.json` + sweep contradicting tests in the SAME commit.

**Files:** `config.toml`, `config.schema.json`, `docs/glossary.md`, `docs/architecture.md`, `README.md`, `README.ja.md`, any `ConfigSchemaDriftTests`/`WindowFieldsFallbackTests`/`FacetConfigTests` asserting `[grouping]`/`[[tag]]`.

- [ ] **Step 1: `config.toml` (repo root)** — delete the `[grouping]` block + every `[[tag]]` table + any `by=tag` sample/commentary. Confirm the surviving template is workspace/section-only.
- [ ] **Step 2: Regenerate the schema** — `swift run facet --emit-schema > config.schema.json` (or the project's emit path). Confirm `[grouping]`/`[[tag]]`/`by` are gone from the JSON.
- [ ] **Step 3: `docs/glossary.md`** — delete `[grouping] by=tag` / tag-mode / `TagModel` / `lens` bitmask entries; ensure `lens`/`active section`/`tag` (as a window attribute) read correctly under the section model. `docs/architecture.md` — drop the by=tag grouping from any two-machineries / grouping table. `README.md` + `README.ja.md` — remove tag-mode + `facet tag` + `lens --add/...` from the CLI surface; keep them bilingually in sync (`readme-bilingual`).
- [ ] **Step 4: Stale-test sweep** — `grep -rn "grouping\|by=tag\|by = \"tag\"\|\[\[tag\]\]\|TagModel" Tests/`; update or delete every test asserting deleted behavior (e.g. a `ConfigSchemaDriftTests` comparing against the regenerated schema; a `FacetConfigTests` for `effectiveGrouping`). The schema-drift test must compare against the freshly emitted `config.schema.json`.
- [ ] **Step 5: `swift build` green** + glossary/README terminology consistent (`CLAUDE.md` Terminology rule — terms land in the same PR as the code).
- [ ] **Step 6: Commit.**

```bash
git commit -am ":memo: docs(config)!: drop [grouping]/[[tag]] from template/schema/glossary/architecture/README + stale-test sweep (EX-4.4)"
```

---

## Host-verify (トミー operates; synthetic input NG, fresh per-op consent)

Run after the whole branch builds + the whole-branch adversarial review is clean. `./run.sh` (AX re-grant in System Settings ▸ Accessibility if the re-sign drops it). Verify (exact commands + expected log lines provided at host-verify time):

1. **Regression (highest risk):** facet adopts windows, no crash, AX writes land — `Set<String>` tags didn't break normal operation.
2. **`window --tag` ungated + works under section model:** `facet window --tag web` on a focused window → `query`: `tags=['web']`; with a `type="lens" match='tag~=web'` section active, the next reconcile gathers/parks by the new tag (reconcile-driven, not synchronous park).
3. **`facet tag …` + `facet lens --add/…` are GONE:** unknown-verb `exit 2` (loud, per house Rule of Repair).
4. **lens activate/clear (the 2-system surface):** `facet lens "Web"` gathers union; `facet lens --clear` restores.
5. **startup = first workspace:** fresh `./run.sh` → active = first `type="workspace"` section, no lens.
6. **grid/rail no longer exit-2:** (n/a — tag mode gone; views unconditional).
7. **leftover `[grouping]`/`[[tag]]` in a config is silently ignored** (no crash, clamps to workspace/section model).

---

## Self-Review

**1. Spec coverage** (revised-plan EX-4 row + canon ⑬⑭ + トミー decision):
- `[grouping] by=tag` deleted → EX-4.2c (Grouping enum, config, fatalConfigErrors). ✓
- `[[tag]]` + UInt64 bitmask tag-mode deleted → EX-4.2 (machinery) + EX-4.3 (TagModel/storage). ✓
- tag STORAGE migration UInt64→string-set + own tests → EX-4.3 (`WindowTagsTests`). ✓
- grid/rail tag-mode exit-2 lifted → EX-4.2a (Main.swift :656-667). ✓
- CLI 2-system (drop composition/vocab, keep `lens NAME/--clear` + `window --tag/...`) → EX-4.2a + EX-4.3. ✓
- startup = first type=workspace → EX-4.1. ✓
- docs/glossary/README/schema → EX-4.4. ✓

**2. Placeholder scan:** migration code blocks (EX-4.3 Steps 3-6) are complete; deletion steps name exact file:line + the surviving shape (a deletion plan can't show "complete code" for removed lines — it shows the exact targets + the post-state + a `grep` gate). No "TBD"/"handle edge cases".

**3. Type consistency:** `WindowSlot.tags: Set<String>` (storage) vs `Window.tags: [String]` (display, sorted at the `makeWindow`/query seam) vs `ApplyPlanWindowFields.tags: [String]` (ordered apply-sim) — three deliberate types, bridged by `.sorted()` at the overlay. Mutators return `Bool` (EX-4.3) replacing `RetagVisibility?` (EX-4.2) — the `NativeAdapter+Tagging` rewire (EX-4.3 Step 5) is where the return-type change lands; until then (EX-4.2) they keep `RetagVisibility?` but the adapter ignores it (reconcile owns visibility).

**4. Risks carried into review:**
- `LayoutGrouping` deletion: all 6 refs are `with: .tag` (verified) — but re-grep before C1 to catch any merge-in-flight new use.
- Section machinery accidental deletion (critic): `applySectionLens` / `setActive` gate / `activeSectionLensApplyTags` are VERIFY-ONLY — the whole-branch review must confirm they're untouched.
- `window --tag` reconcile latency: dropping synchronous park/restore means a tag change reflects on the next reconcile (D3). Confirm `applySectionLensReconcile()` after the mutation makes it prompt (host-verify item 2).
- `--layout` typo rejection must survive `LayoutGrouping` deletion (it validates via `LayoutRegistry`/canonical layouts, not `LayoutGrouping`) — verify in C1.

## Execution Handoff

Plan complete. Execution = **Ultra** (per `facet-exclusive-model-execution-plan`): in-place on `feat/ex4-tag-mode-removal` (host-verify loop needs the main working dir); implementer = main loop or a sequential implementer subagent with full verified context; **adversarial 3-lens review per task** + **whole-branch review** at the end; push/merge + host-verify await トミー go. Before executing, run a **3-lens adversarial plan review** of THIS doc and fold the must-fixes.
