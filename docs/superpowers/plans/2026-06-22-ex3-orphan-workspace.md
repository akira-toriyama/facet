# EX-3 — Nullable `WindowSlot.workspace` (迷子) + symmetric DnD move + new-window apply inheritance

> Phase EX-3 of the exclusive-selection model. Parent plan:
> [2026-06-21-exclusive-model-revised-plan.md](2026-06-21-exclusive-model-revised-plan.md) (EX-3 row).
> Design canon: memory `facet-tag-unification-design` (🔄 2026-06-20 排他選択 14決定).
> Grounded by codemap workflow `wf_a4c7303d-2a6` (7 readers, 2026-06-22) + direct source verification of every
> load-bearing fact below. EX-0/EX-1/EX-2 SHIPPED on main `f5ebf6d` (3-view unified highlight complete).
> Confidence: **high** on the foundation + move primitive + 迷子 receptacle; the grid/rail lens-DnD scope is a
> deliberately-declared follow-up (EX-3b).

## End state (what EX-3 delivers)

1. **`WindowSlot.workspace` becomes `Int?`** — a window can belong to 0 or 1 workspace. `nil` = the window is not
   assigned to any facet workspace (it lives only via tags/lenses, or is a true 迷子).
2. **Symmetric DnD move** — dragging a window onto a **lens** section now RELOCATES it out of its workspace
   (`workspace → nil`) in addition to applying the lens's `apply` tags. This is the "全部移動" flip (canon ⑤⑥):
   ws→ws / ws→lens / lens→ws / lens→lens all become pure relocations. Today a ws→lens drop keeps the source
   workspace (併用) — EX-3 makes it leave.
3. **New windows inherit the active section's `apply`** so a launched window is **always visible** (canon ④⑨): when a
   lens is active, a new window gets the lens's `apply` tags (joins the lens, visible in the union) **and keeps
   `workspace = activeIndex` as its home** (never an orphan-on-birth). When a workspace is active, unchanged.
4. **迷子 receptacle** = an explicit `type="lens"` section with `match = 'not workspace'` (catch-all over windows
   with no workspace). No new filter field, no `unassigned` type revival. Orphans with no receptacle are
   **invisible-but-logged** (canon ⑧, never auto-homed to WS1).

## Key grounded findings (the nullable reality is smaller than "30 sites")

The dominant read pattern is `slot.workspace == n1Based` / `== activeIndex` / `== old`. **EQUALITY** comparisons
(`==` / `!=`) between `Int?` and `Int` DO compile and are nil-safe — the non-optional is implicitly promoted to
`Optional` and `nil` never equals a valid index (empirically verified: `let a: Int? = nil; a == 5` compiles →
`false`, `a != 5` → `true`). So every `== / != n1Based|activeIndex|old` filter site needs **no change** — an orphan
is naturally excluded from per-workspace membership / park / restore / remove filters.

**This nil-safety does NOT extend to** relational comparisons (`<` / `>` / `<=` / `>=` — `Int? >= Int` is a compile
error, must unwrap), arithmetic (`slot.workspace - 1`), or dictionary subscripts (`map[slot.workspace]`,
`layoutTrees[slot.workspace]`). Every such USE of the value (not a `==`/`!=` test) needs an explicit `guard let` /
`if let` / `?? sentinel`. This collapses the churn to a small set of genuine fixes (equality filters excluded):

| Genuine fix site | File:line | Change |
|---|---|---|
| `layoutTrees[slot.workspace]` subscript (only direct-subscript site) | `WorkspaceCatalog+DnD.swift:18,20` (`toggleOrientation`) | `guard let ws = slot.workspace` → subscript `ws`; orphan early-returns (no tree) |
| `snapshot` byWS grouping `windowMap[w.id]!.workspace` (nil key) | `WorkspaceCatalog.swift:768-770` | filter orphans OUT of `tracked` BEFORE the `Dictionary(grouping:)` (`.filter { windowMap[$0.id]?.workspace != nil }`) so no nil key forms; emit one `Log.line` per dropped orphan (canon ⑧ invisible-but-**logged**) |
| `attachToLayout(id, workspace: slot.workspace, …)` callers | `WorkspaceCatalog.swift:573`; `+SectionLens.swift:85,132`; `+Reconcile.swift:241` | `guard let ws = slot.workspace else { continue }` (orphan never re-attaches) |
| `workspaceName(_ n1Based: Int)` | `+SectionLens.swift:48` | signature → `Int?`, `nil → ""` (out-of-range sentinel) |
| `sectionLensVisibleIDsAll` workspaceName | `NativeAdapter+Queries.swift:434` | pass `workspaceName(slot.workspace)` (now `Int?`) → "" for orphan; `not workspace` then matches |
| `facetState` query export | `NativeAdapter+QueryCommand.swift:140-147` | `idx: Int? = slot.workspace`. Orphan handling: the relational name lookup (`idx >= 1 && idx <= count` — won't compile on `Int?`) and the `cat.mode(of: idx)` / `cat.orderedMembers(of: idx)` calls (expect `Int`) all need an `if let ws = idx { … } else { name = "迷子"; mode = "float"; master = false }`. Window still reported, distinctly labelled |
| `focusMark` switch + log | `NativeAdapter+Tagging.swift:35-36,45` | line-35 `slot.workspace != activeIndex` is nil-safe (no change); line-36 arithmetic `switchWorkspace(toIndex: slot.workspace - 1)` won't compile → `guard let ws = slot.workspace else { Log.debug("focus-mark: orphan, no WS to switch"); return false }` then `ws - 1`; log line-45 `slot.workspace ?? -1` |
| `remapIndices` `map[slot.workspace]` (dict subscript, `Int?` key won't compile; for-`where` cannot `let`-bind) | `WorkspaceCatalog.swift:516-517` | rewrite to a body guard: `for (id, slot) in windowMap { guard let ws = slot.workspace, let mapped = map[ws] else { continue }; windowMap[id] = WindowSlot(workspace: mapped, …) }` — orphans skip the remap unchanged |
| `setMaster` guard | `NativeAdapter+Apply.swift:56` | already `guard let ws = …?.workspace`; with `Int?` becomes a double-optional flatten |

**Orphan→workspace already works.** `WorkspaceCatalog.moveWindow(_:to n1Based:Int)` (`WorkspaceCatalog.swift:642`)
guards `current.workspace != n1Based` (nil-safe → proceeds for an orphan source) and routes outcome via
`n1Based == activeIndex` / `current.workspace == activeIndex` (nil-safe). So un-orphaning a window into a workspace
needs **no change** to `moveWindow` beyond the `Int?` type. The **only new primitive** is workspace→orphan
(`workspace → nil`).

## Locked decisions (canon + grounded; surfaced to トミー in the handoff, not re-litigated)

- **D-A New windows are never orphans on birth.** Adopt `workspace = activeIndex` always; if a lens is active,
  additionally apply the active lens's `apply` tags so the window matches the lens and is visible in the union NOW,
  and remains visible in `activeIndex` after the lens clears. Honors canon ④⑨ "必ず見える" most robustly; lowest
  risk. Orphans arise **only** from explicit DnD move to a lens (D-B). (Resolves the codemap fork where readers
  split between activeIndex vs nil-on-birth.)
- **D-B Orphans are created only by an explicit MOVE onto a lens.** ws→lens DnD = un-apply source (leave workspace
  → `workspace=nil`) + apply dest lens tags. This is the canon ⑤⑥ "全部移動". (`ws=nil` ≠ 迷子: a window moved to
  the `web` lens has tag `web`, so it is a member of `web`, not a true orphan. A **true 迷子** is `ws=nil` AND
  matching no active section — only reachable by stripping the last membership.)
- **D-C 迷子 receptacle = `type="lens"` `match='not workspace'`** (or `'not workspace and not tag'` for strict).
  The filter grammar already supports bare-presence atoms + `not` (`FacetFilter.swift:23-31,305-306,465-468`); a
  nil-workspace window projects `workspaceName=""` → `filterHas("workspace")=false` (`FilterProjection.swift:73-74`)
  → `not workspace` matches. **No new `FilterField`, no `unassigned` revival** (canon ⑦ Q20).
- **D-D Orphans invisible-but-logged** (canon ⑧) — never auto-homed to WS1. `snapshot` drops them; a `Log.line`
  fires when a window becomes/stays orphan with no active receptacle.
- **D-E The move primitive keeps `ApplyResolver.inverse` tag-only** (per its frozen PR8 contract). The
  source-workspace un-apply (→nil) is surfaced as a new `ApplyResolver.Plan` signal and executed by a new
  backend `orphanWindow(_:)` primitive — NOT by overloading `inverse` (codemap-recommended option B/C).
- **D-F 迷子 receptacle ships uncommented + "推奨!!" at the top of the section block** in `config.toml` (canon ⑦
  explicit トミー preference). One codemap reader argued commented-opt-in; canon wins.

## Sub-task breakdown (branch `feat/ex3-orphan-workspace`; sub-task = commit; TDD where pure; adversarial review per task)

Per parent-plan biggest-risk #1: **land the nullable foundation as pure catalog + exhaustive CI XCTest FIRST; AX /
view wiring after.** `swift build` is the local gate; XCTest runs in CI only — write defensively.

### EX-3.1 — Nullable foundation (pure catalog + CI tests; NO new behavior)
`WindowSlot.workspace: Int?`. Sweep the genuine-fix table above; annotate each touched site with an inline comment
naming its orphan policy (`// orphan: skip` / `// orphan: drop from snapshot` / …) so the vanish-bug surface is
auditable. `==`/`!=` filter sites get a one-line confirming comment ("nil never == index — orphan excluded") but no
code change; every **relational / arithmetic / dict-subscript** USE of the value is unwrapped per the table.
**Compiler-as-net:** because every un-unwrapped `Int?` use is a hard compile error, a green `swift build` proves the
churn sweep reached every site — no missed read can silently compile (this is the primary vanish/crash mitigation).
New `FacetAdapterNativeTests` (CI): every catalog op is orphan-safe (no crash, no nil-key, orphan excluded from
snapshot/membership + a snapshot log fires, orphan survives `removeWorkspace`/`remapIndices` untouched, `moveWindow`
un-orphans into a workspace correctly — `.restore` for active dest, `.stateOnly` for inactive). **No orphans can
exist yet** (nothing sets nil) → this commit is pure foundation, behavior-identical for all existing flows.

### EX-3.2 — Workspace→orphan relocation primitive + symmetric move wiring (catalog + FacetCore + Controller; CI tests)
- Catalog: `mutating func setOrphan(_ id:) -> MoveOutcome` (set `workspace=nil`, `detachFromLayouts`,
  `clearLeaveFocus`, return `.park(ref)` if it was on `activeIndex` else `.stateOnly`; reject sticky/stashed like
  `moveWindow`). Keep `moveWindow(_:to:)` for ws→ws / orphan→ws (already nil-safe from 3.1).
- Backend protocol (`Backend.swift`): `func orphanWindow(_ id: WindowID)` (ext default no-op for the test stub).
  NativeAdapter implements → `catalog.setOrphan` + apply the park/restore outcome through the same anchor chokepoint
  as `moveWindow`.
- `ApplyResolver.Plan`: **INTRODUCE a NEW field** `relocateSourceToOrphan: Bool` (a pure `Bool`, no backend type —
  layer-clean) computed in `plan()` as `destIsLens && !workspaceName.isEmpty` (the source currently lives in a
  workspace and the dest is a lens). When true, the dest-lens match invariant (`satisfiesAfterApply`, ApplyResolver.swift:188-190)
  must simulate with `workspaceName=""` (post-orphan), since the window leaves its workspace — pass the
  empty name into that one call so a ws→lens move is correctly accepted/rejected against the post-move state.
  All existing `Plan` initializer call sites + the `Plan` test fixtures must pass the new field (default `false`).
- `Controller.runApplyPlan` (`Controller+Apply.swift:66`): after `inverse` removeTags, if
  `plan.relocateSourceToOrphan` call `bk.orphanWindow(id)` (instead of / in addition to the existing
  `destWorkspaceIndex` branch, which stays for ws dests), then `forward`.
- FacetCore CI tests: `ApplyResolver.plan` sets `relocateSourceToOrphan` correctly across ws→lens / lens→lens /
  orphan→lens / ws→ws; the post-orphan match sim; inert/snap-back unchanged. Catalog CI: `setOrphan` outcomes + the
  orphan↔workspace round trip.

### EX-3.3 — New-window apply inheritance (adapter orchestration; pure helper CI-tested)
At the adoption seam (`NativeAdapter+Queries.refreshCatalog`, before `catalog.reconcile`), resolve the active
section: if `catalog.activeSectionLens != nil`, compute the lens section's `apply` tag set and pass it so the new
window is tagged on adoption (keeps `workspace = activeIndex` per D-A). Pure helper
`activeSectionApplyTags() -> [String]` (or reuse the section config lookup) is CI-tested. Loud `Log.debug` of the
inheritance. **Declared gap:** a pure-condition lens (no `apply`) + a non-matching new window stays in its home
workspace, parked until the lens clears (the canon ⑨ "lens が workspace に緩む" auto-relax is NOT implemented in
EX-3 — declared, not implicit).

### EX-3.4 — 迷子 receptacle config + match plumbing + docs (CI test on the match)
- `workspaceName(nil) → ""` (done in 3.1) makes `not workspace` work end-to-end; add a focused FacetCore/adapter
  CI test: a `ws=nil` window matches `not workspace`, a workspaced window does not.
- `config.toml`: add the 迷子 receptacle as `type="lens"`, `match='not workspace'`, uncommented + "推奨!!" header,
  at the top of the desktop-1 section block (D-F).
- `glossary.md`: new `### 迷子 (orphan)` term; `### active section` note that `workspace` may be `nil`.
- `architecture.md`: nullable-workspace note in the section read-path.
- `README.md` + `README.ja.md`: orphan / 迷子 receptacle behavior.
- `FacetConfig+Spec.swift`: clarify `unassigned` is DEFERRED; the receptacle is an explicit lens.

### EX-3.5 — Tree DnD semantic flip (verify + minimal wiring; host-verify)
The tree section-model DnD (`SidebarView+Drag.swift` mode=2 → `Controller.applyMove`) already drops a window onto a
lens section. EX-3.2's resolver+runApplyPlan change makes that drop now relocate the source out of its workspace.
This sub-task is the **verification + any tree-specific wiring** (inert/snap-back unchanged; the drop target id for a
lens section is already computed). No new tree gesture code expected.

### EX-3.6 — grid/rail lens-cell DnD — **DECLARED FOLLOW-UP (EX-3b), not in EX-3 core**
EX-2 made grid/rail lens cells click-only. Re-enabling them as drag sources / drop targets (so "全部移動" works in
grid/rail too) is meaningful view churn across both views' gesture seams. EX-3 core delivers orphan creation via
**tree DnD + the receptacle** (the dense primary dogfood surface), keeping the highest-churn work (catalog + resolver
+ adoption) coherent. grid/rail lens-DnD lands as **EX-3b**, re-planned at its start. This is a loud declared gap,
not an implicit skip. **CLI orphaning** (a window-attribute verb to leave a workspace) is deferred to **EX-4** (the
CLI 2-system).

### EX-3 host-verify (トミー operates; synthetic input only with fresh consent)
Build + run; with a 迷子 receptacle configured on desktop 1: (1) drag a window from a workspace onto a lens section →
it leaves the workspace (gone when you return to that WS), appears in the lens; (2) `facet lens "迷子"` (the
receptacle) → all orphans gather; (3) launch a window while a lens is active → it appears in the lens immediately AND
in `activeIndex` after `--clear`; (4) an orphan with NO active receptacle is invisible + a log line fired (never
auto-homed); (5) no window vanishes mid-gesture. Provide exact commands + expected `parked=N` / gather / orphan log
lines.

## Risks (carried from codemap, with mitigations)

1. **Vanish bug** (biggest): a lazy `guard let … else { return }` that silently drops an orphan. Mitigation: every
   touched site gets an explicit policy comment; EX-3.1 is pure + CI-tested before any orphan can exist; whole-branch
   review greps for unguarded `slot.workspace` reads.
2. **Dictionary subscript trap**: only `WorkspaceCatalog+DnD.swift:18,20` subscripts `slot.workspace` directly — all
   others use a guaranteed `n1Based`. Fixed in 3.1; CI test proves no nil-key crash.
3. **Post-orphan match invariant**: the resolver's `satisfiesAfterApply` must simulate `workspaceName=""` when
   relocating to orphan, else a valid ws→lens move is wrongly refused or a stale match passes. Covered by EX-3.2
   tests.
4. **Adoption timing**: apply the lens tags BEFORE the reconcile tile/park so a new lens-window doesn't flash in
   `activeIndex` then re-park. Resolve at `refreshCatalog` before `reconcile`.
5. **Cross-WS drift heal interaction**: a stale cross-desktop window must still be evicted before lens union tiling
   (existing `facet-native-space-drift-heal`); orphans don't change that ordering but the whole-branch review must
   confirm orphans aren't union-tiled across desktops.
6. **Move not cycle-safe**: setWorkspace is last-writer-wins; ws→lens→ws does not restore the prior intra-WS layout
   position. Accepted (explicit user action, not undo). Documented.

## Open items surfaced to トミー (proceeding on canon; flag to override)

- Proceeding per canon ⑧ (orphans invisible-but-logged, no auto-home) and ⑦/Q20 (迷子 = explicit `type="lens"`,
  not `unassigned`). **Confirm-or-veto** — not blocking implementation of the foundation.
- Proceeding per canon ⑦ that the receptacle ships **uncommented + 推奨** (D-F), over a codemap reader's
  commented-opt-in suggestion.
- **Phasing call (Claude-delegated per canon "実装フェーズの刻み方は全てクロード委任"):** grid/rail lens-cell DnD is
  EX-3b (follow-up), not EX-3 core. Flag if you want it folded into EX-3.
