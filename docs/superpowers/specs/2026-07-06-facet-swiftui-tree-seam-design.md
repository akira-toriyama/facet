# facet SwiftUI tree/search seam pilot (F1) — design

- **Task**: `t-tsxg` (facet #18 SwiftUI pilot, F1 seam)
- **Epic**: `t-d75q` (facet UI → SwiftUI/sill migration)
- **Date**: 2026-07-06
- **Status**: design agreed (5 decisions locked), claims verified against
  current sill/facet code, ready for `writing-plans`

> **⚠️ Retirement note (2026-07-11)** — this spec predates the **board
> layer removal** (`t-0sbm` / PR #403, merged 2026-07-11). The former
> browser-tab **board** layer — `BoardBand` / `RailBoardBand`, the "board
> band" host chrome, the "board feed" push path — was **deleted** with that
> layer; a mac desktop is now typed directly (`[desktop.N]
> type = "workspace" | "lens"`) and a **lens desktop is tree-only** (no
> band). The F2 scope below therefore **excludes board-band** (nothing to
> migrate), and the "stays intact" invariants have been corrected to drop
> `BoardBand` / board feed. The 2026-07-06 architecture diagram in §2.2 is a
> dated snapshot — read its "board band" cell as historical.

## 1. Goal

Prove the **SwiftUI-on-sill seam** on facet's hardest view — the **facet
view `tree`** (`FacetViewTree`) — covering its three load-bearing
behaviours: **rendering, DnD, keyboard-nav**, plus the type-to-filter
**search** bar. If the seam holds here, it unlocks F2 (menus / badges /
rename / thumbnail-grid) and the other atelier apps
(#19–#22).

The migration is **View-layer only**. `FacetAdapterNative` (AX/CGS),
`FacetAccessibility` (SkyLight), `FacetCapture` (ScreenCaptureKit), the
`WindowBackend` protocol, `TreeController` protocol, `FacetCore` value
types, and `KbNav`/`fuzzyMatch` pure logic are **untouched**. The seam is
purely `FacetView*` ↔ sill `ThemeKitUI`.

## 2. Decisions (the 5 locked 論点)

1. **Content-only migration.** Keep `KeyablePanel` / `PanelHost` as the
   **AppKit host**; embed the SwiftUI tree + search as an `NSHostingView`
   inside the existing panel. **Do NOT migrate the window shell to sill
   `WindowShell`** in this pilot — that needs three sill blockers
   (borderless+resizable, runtime `wantsKey` gate vs `becomesKeyOnlyIfNeeded`
   coupling, `canBecomeMain`) and the #66 activation/key dance stays
   host-side regardless. WindowShell is a **later slice** (deferred, not
   cancelled).

2. **Bend facet to sill's fixed row anatomy** (`sill` is canonical;
   facet UI change is acceptable). facet's variable-height 3-line window
   row maps onto sill `ListItem`'s fixed anatomy
   (`image + primary + secondary + badges[] + 1 trailing + tint`). Badges
   (master / float / hidden / scratchpad / mark / **tags**) move from a
   wrapped 3rd line to the **trailing badge cluster**. Extend sill's
   anatomy (**T7**) **only if** something is genuinely inexpressible —
   fit-first (overflow rule + T7 threshold in §4.3).

3. **Layout-mode badge glyphs**: `spiral` = Phosphor `spiral` (upstream,
   same family); `bsp` + `master-left/right/top/bottom/center` = a small
   **custom SVG set (6 glyphs)** authored in Phosphor's fill / viewBox-256
   / currentColor style. **No new foreign icon family.** `stack` / `grid`
   / `float` stay on existing Phosphor slugs
   (`stack` / `squares-four` / `app-window`). Rationale: `master-center`
   has **no clean source in any permissive set** (verified across Lucide /
   Tabler / Material Symbols / Remix / Fluent / Phosphor — all place the
   inset in a corner or draw a camera-focus frame), and a 5-glyph master
   set must be visually coherent, so drawing all 6 tiling shapes together
   beats stitching foreign families + inversion-named slugs + one lone
   custom center.

4. **DnD**: (a) **drop `performSwap`** (mode 3 header↔header swap) from the
   pilot — it is **by-workspace-degrade only** and never fires in the
   section model (the primary path); its route stays in the code,
   **untouched but unwired**. (b) **Accept post-hoc rejection** — no
   `dropTargetValidator`; facet keeps its existing optimistic-fire →
   server-side snap-back model. The only loss vs today is the "invalid
   target" visual before release. **T3 `dropTargetValidator` is the top
   fast-follow sill PR**, not a pilot blocker.

5. **PR structure**: 2 sill PRs (T1 binding, glyph vendor) + 3 phased
   facet PRs (render → DnD → search). See §8.

**Net**: the only *mandatory* sill code PR inside the pilot is **T1**
(surface the `ThemedTextField` callbacks/binding through the SwiftUI
bridge). Everything else is deferred, resource-only, or facet-side.

> **Claim-verification note (2026-07-06)**: every structural claim below
> was checked against current sill/facet code (workflow `wkyjidrtr`,
> 20/22 CONFIRMED). Two were corrected and folded in: the four DnD commit
> routes do **not** all go through `TreeController` (§3); `FacetView`
> links `Palette`/`PaletteKit`/`Effects` only, not `ConfigSchema` (§5).

## 3. Architecture — what moves, what stays

```
                 AppKit host (STAYS)              SwiftUI content (NEW)
  ┌───────────────────────────────────┐   ┌──────────────────────────────┐
  │ KeyablePanel / PanelHost          │   │ ThemedListView<ID>  (tree)   │
  │  · wantsKey / canBecomeMain       │   │ ThemedTextFieldView (search) │
  │  · enterActive/exitActive (#66)   │──▶│  hosted via NSHostingView    │
  │  · global keyDown monitor         │   │  palette via .environment    │
  │  · board band · handle bar        │   └──────────────────────────────┘
  │  · borders / vibrancy             │                  │
  │  · loading-skeleton overlay       │                  │ callbacks
  │  · section-header context menu    │                  ▼
  └───────────────────────────────────┘   TreeController protocol (STAYS)
             ▲  data (apply)                            │
             │                                          │
  Controller (STAYS) ── lastSections:[ProjectedSection] ┘
             │
  WindowBackend / FacetAdapterNative / FacetAccessibility  (UNTOUCHED)
```

**Stays AppKit / host-side** (not migratable, or out of pilot scope):
- `KeyablePanel` / `PanelHost` window shell + chrome (§2.1).
- The **key/activation dance**: `enterActive`/`exitActive`,
  `NSApp.setActivationPolicy(.regular↔.accessory)`, the **#66
  "hand key BACK before focusing"** invariant
  (`exitActive(restore:false)` **before** `handleClick`/focus). This is
  NSPanel/NSApp-level; `@FocusState`/`.onKeyPress` cannot express it.
- The **global `NSEvent.addLocalMonitorForEvents(.keyDown)`** swallow-or-
  passthrough key hook, gated on `panel.isKeyWindow` (`installKbMonitor` →
  `handleKbKey`). **Stays host-side and keeps owning all tree keyboard
  input** (see §4.8) — SwiftUI `.onKeyPress` is *not* used for tree nav.
- Panel-move (mode 1 → `win.performDrag`),
  handle bar (`HandleBar`), the **loading-skeleton overlay** (§4.1),
  section-header right-click context menu, sibling keyable editors
  (`TagEditPanel` / `SectionRenamePanel`).
  (Was: `board band (BoardBand)` — retired with the board layer, `t-0sbm`.)

**Stays untouched (pure / backend / protocol)**:
- `WindowBackend`, `TreeController` (@MainActor protocol, all
  FacetCore-neutral params), `ProjectedSection` (Sendable/Equatable,
  stable String `id`), `KbNav.swift` (pure index math), `fuzzyMatch`
  (FacetCore), `FilterProjection.project`, and the entire AX/CGS/SkyLight
  backend.
- The **DnD commit routes** — `applyMove` / `reorderSection` go through
  the @MainActor `TreeController`; `bk.moveWindow(toWorkspaceIndex:)` and
  `performSwap` are **view-side commits dispatched directly on `cliQueue`**
  (not through the Controller). `performSwap` is untouched **and unwired**
  in the pilot (§2.4a). The SwiftUI `onDrop` handler calls the same
  routes verbatim.

**Moves to SwiftUI (the seam)**:
- `SidebarView` (+Draw / +Drag / +KbNav / +Menus) immediate-mode NSView →
  `ThemedListView<ID>` in an `NSHostingView`.
- `SearchBar` (+ `SearchFieldDelegate`) custom NSView → sill
  `ThemedTextFieldView` (needs T1).
- `IconResolver` SF-Symbol raster path → Phosphor slug name-map
  (template NSImage, tint deferred to SwiftUI `.foregroundStyle`).

## 4. Component design

### 4.1 Host embedding, sizing & scroll (facet-1)

`PanelHost` today builds an `NSScrollView` (FlippedClipView contentView,
`SidebarView` documentView, `ThemedScroller` per axis). **The outer
`NSScrollView`, `FlippedClipView`, and `ThemedScroller` are retired.** The
panel content becomes `NSHostingView(rootView: TreeContentView)`;
**`ThemedListView` owns vertical scrolling itself** (it is a SwiftUI
`ScrollView`, indicators hidden) — there is exactly one scroller, no
double-scroll. `horizontalContentScroll` handles long titles (natural
width, no truncation). The themed-knob loss is accepted for the pilot
(re-add later if missed).

`PanelHost` still lays out its AppKit chrome vertically:
`[HandleBar | search band | hosting view]`. **Panel sizing**:
`NSHostingView.fittingSize` does **not** work here — `ThemedListView`'s root
is a greedy SwiftUI `ScrollView` (verified `ThemedListView.swift:253`) that
fills its scroll axis and never self-reports a content-fitting height, so
`fittingSize` would collapse the Spotlight-style shrink-to-content panel.
Instead compute the intended content height by **summing sill's public
`ListMetrics.forDensity` per built row** (header1 = 28 / header2 = 40 /
singleRow = 30 / twoLineRow = 46); panel height =
`min(sum, screenMaxHeight)` (the existing screen-relative clamp). When the
sum exceeds the clamp, `ThemedListView` scrolls internally — this replaces
the old `SidebarView.update(...) -> CGFloat` height-return contract.
`FlippedClipView`'s top-anchor requirement dissolves (SwiftUI `ScrollView`
is top-anchored by default).

**Loading skeleton**: stays a **host-side AppKit overlay** that `PanelHost`
shows over the hosting view, driven by `Controller.showLoading`, and
cleared on the next content-ready signal (§7.4). It does **not** move into
the SwiftUI content — this keeps the CLI `--loading` trigger entirely
Controller-side.

### 4.2 View-model / data-in (facet-1)

Introduce **one `@Observable` tree view-model** injected via
`.environment`, driving both the list data and the palette (§4.6). It
holds: the flattened `[ListItem<ID>]`, `selection`/`highlight`/`collapsed`
sets, `query`/`searching`, and the loading/optimistic flags. This single
shape is the target for all three phases (no "or feed bindings directly"
alternative).

`Controller.apply` already projects **once** into
`lastSections: [ProjectedSection]` + `lastActiveLensID: String?` shared by
tree/grid/rail (verified: `Controller.swift:1076/1224/1229`, single
`SectionOrder.apply`). Only the tree push (`sidebarView.update(...)` at
`Controller.swift:1369-1373`) changes: it feeds the view-model instead.
The projection and grid/rail `layoutCells()` push **stay
intact** (partial migration — two rendering models coexist behind one
`apply()`). (Was: "projection, board feed, and grid/rail …" — the board
feed was removed with the board layer, `t-0sbm`.)

Additive FacetCore / view-model work (low-risk):
- The SwiftUI row **ID is the composite `(group, WindowID)`** (a small
  `Hashable & Sendable` struct), never `WindowID` alone — one window
  appears in several sections under multi-match (`group` = render-group
  ordinal; verified `TreeRow.swift`). Section-header IDs use the stable
  section id.
- Pre-merge the AX title (`win.title.isEmpty ? override : win.title`) in
  the view-model so a row binds one resolved string.

### 4.3 Tree render, row anatomy & collapse (facet-1)

Flatten `[ProjectedSection]` → `[ListItem<ID>]` each render:
- **section header** → `kind = .sectionHeader(subtitle:)`; `subtitle` =
  layout-mode abbrev (workspace sections only); leading glyph via `image`
  (lens → funnel, unassigned → archive); `primary` = kind-prefixed label
  (`workspace · X` / `lens · X` / `unassigned · X`).
- **window row** → `image` = app icon (`AppIcons.icon(forPID:)`, rendered
  `.original`), `primary` = app name, `secondary` = title, `badges[]` =
  master / float / hidden / scratchpad / mark / **tags** (role-coloured),
  `tint` reserved for future desktop/section colour.

**Badge overflow rule** (makes "fit-first" testable): the trailing cluster
shows the status badges (master/float/hidden/scratchpad/mark) first, then
tags up to a cap of **≈3 visible tag badges**; further tags collapse into a
single **`+N`** overflow badge. **T7 (extend sill anatomy) is triggered
only if** the essential status badges themselves cannot fit alongside
`+N` — i.e. never for tags alone. (Full tag legibility is a hover/preview
concern, out of pilot scope.)

Two `Cell`/`update()` builders unify into **one** row-building function
(kills the byte-identical-drift the current code warns about). Height is
sill's density table — **delete facet's `windowRow()` height ladder**
(28/48/72). `ThemedListStyle`: `selectionMode = .single`,
`highlightStyle = .outline` (**cursor ≠ selection** ring),
`showsDividers`, `zebra`, `horizontalContentScroll`, `hosted = false`.

**Selection vs cursor** (central): `selection: Binding<Set<ID>>` (the `hot`
fill, active section only) and `highlight: Binding<ID?>` (the roving kb
cursor outline) stay **two separate bits**, exactly as today. `KbNav.swift`
pure fns reused verbatim.

**Collapse state** lives in the **view-model `@State`, keyed by stable
section id**, and survives re-projection/`apply()` (id-keyed, like the
selection/cursor). `onToggleSection(ID)` → toggle that set; the sill list
reads `collapsed: Binding<Set<ID>>`.

`onActivate(ID)` → run facet's **#66** dance host-side:
`exitActive(restore:false)` **then** public-AX focus via the existing
`handleClick`/`TreeController` routing.

### 4.4 Search (facet-3, needs sill T1)

Replace `SearchBar` + `SearchFieldDelegate` + custom draw with sill
`ThemedTextFieldView` (variant `.standard`, `label: nil` →
placeholder-only, `leading: "magnifying-glass"`). Wire via **T1**:
- `onChange` → `viewModel.query` → `fuzzyMatch` filter (FacetCore,
  app-name + title only, zero-match sections drop — logic moves into the
  view-model, stays pure).
- `onReturn` → `kbActivate`; `onMoveUp/Down` → `kbMove(∓1)`;
  `onEscape` → clear-if-nonempty else `leaveSearchKeepingNav`.
- Controlled `Binding<String>` (NOT seed-once) — Escape-clear + enter-search
  push text INTO the field; the binding must respect the "push model→field
  only while NOT first responder" rule to avoid clobbering live typing.
- `@FocusState` → `ThemedTextField.focus(selectingAll:)` for `s`-to-search.
- IME: `isComposing` (`hasMarkedText`) gating is **built into** sill's
  `ThemedTextField` (verified: auto-suppresses onReturn/onEscape/onMove
  during marked text) — a superset of facet's manual guard.
- **Gains a clear-× button** (`trailing`, fires `onChange("")`) — accepted
  UX change.
- `Ctrl-N/P` and `Tab` in search sub-mode are **preserved via the host
  global monitor** (§4.8), not sill closures — no behaviour loss.

### 4.5 Icons (facet-1)

`IconResolver` collapses from raster-tint (`paletteColors` bake — verified
sole `systemSymbolName` site at `IconResolver.swift:58`) to a pure
**`SF:<name>` → Phosphor-slug name-map**; SwiftUI tints via
`Image(nsImage: phosphorImage(slug)).renderingMode(.template).foregroundStyle(...)`.
Glyph sourcing (full 10 layout modes + tree chrome):

| slug need | source |
|---|---|
| magnifyingglass, pencil, tag, funnel, crown, app-window, eye-slash, caret-up/down, arrow-clockwise, plus, minus, x, stack, squares-four | Phosphor **existing** |
| archive, push-pin, push-pin-slash, tray, arrows-left-right | Phosphor **GAP-A** (curl into sill, resource-only) |
| **spiral** | Phosphor **upstream** (vendor into sill) |
| **bsp, master-left/right/top/bottom/center** | **custom SVG ×6** (Phosphor fill/256/currentColor style) |

**Adapter-layer SF specs are OUT of pilot scope.**
`NativeAdapter+Scratchpad.swift` (adapter) emits ~12 `SF:` icon-spec
strings for **context menus** (verified). Context menus are host chrome /
F2 scope — they **keep resolving via the existing `IconResolver` path**
unchanged. The pilot's name-map covers only the tree-render glyphs (row
badges + section-header + layout badge). No adapter-layer edit in this
pilot; the central slug remap is deferred to the menu migration (F2).

### 4.6 Palette (facet-1)

`ThemedListView` takes `palette: ResolvedPalette` **directly** (verified —
required, non-defaulted) — no SwiftUI `Color` bridge needed for the list
(**T4 deferred**). Inject `ResolvedPalette` through the view-model's
`.environment` box. **The 30 Hz re-theme animator updates only the palette
environment value — it must NOT rebuild `[ListItem]`** (the flatten in
§4.3 runs on section-data change, not on every palette tick). This keeps a
theme animation from re-flattening + diffing the whole list 30×/s (see
§7.7). Keep the **`pal` var name** (CLAUDE.md hard rule) at facet call
sites that remain AppKit.

### 4.7 DnD (facet-2)

`ThemedListStyle`: `draggable`, `dragMode = .both` (dropOnto +
reorderBetween), `showsReorderGrip`. The single `onDrop(DragContext,
DropTarget)` host hook (verified — the sole drag hook) maps to facet's
commits:
- `DropPlacement.onto(id:)` on a section band → `applyMove(windowID:
  fromSectionID: toSectionID: destSourceWorkspaceIndex:)` (via
  `TreeController`).
- section-header **chunk drag** (`.reorderBetween`, `beforeID`) →
  `reorderSection(move:toBoundary:)` (via `TreeController`).
- degrade window move → `bk.moveWindow(id, toWorkspaceIndex:)` (view-side
  `cliQueue`).
- **mode 1 panel-move** stays AppKit (`win.performDrag` at the window/host
  layer — no SwiftUI equivalent).
- **mode 3 header-swap → dropped/unwired** (§2.4a).

Validity is **not** pre-checked (no `dropTargetValidator`, verified
hardcoded `{_,_ in true}` at `ThemedListView.swift:383/436`) — invalid
drops fire `onDrop`, the server-side plan is inert, and reconcile
re-projects the unchanged row (snap-back = no-op). Mouse + keyboard drag
both converge on the same commits (verified: `kbCommitLift` routes to the
same four; sill kb-drag = space lift / arrows aim / return commit / esc
cancel → same `onDrop`). Preserve `prevApp` save + restore so a background
move never leaves facet frontmost (tie to the drag lifecycle).

### 4.8 Keyboard routing (facet-1)

The **existing global `NSEvent` keyDown monitor + `handleKbKey` dispatch
table stays host-side, unchanged**, and remains the sole owner of tree
keyboard input. facet adds **no** SwiftUI `.onKeyPress`/`.focusable` of its
own for tree nav (they have weaker swallow control and cannot express the
#66 / `isKeyWindow` gating). **Caveat (verified):** sill's `ThemedListView`
installs its **own** `.focusable` + five `.onKeyPress` (↑/↓/return/escape/
space) + a list-level focus ring internally, with no `ThemedListStyle`
off-switch (`ThemedListView.swift:282-299`). These do **not** fire because
the host monitor pre-empts the responder chain — `handleKbKey` returns
`nil` for all five keys in nav mode (`Controller.swift:1521-1524`), so the
event is swallowed before SwiftUI sees it. **Swallowing every overlapping
key is therefore a load-bearing invariant**, not an incidental detail. This
is NOT a hidden sill dependency (no third sill PR) — but a Task-10 GUI check
must confirm both: all five keys are swallowed, AND sill's list-level focus
ring does not double-render with facet's own cursor outline (suppress
host-side or file a sill knob as a fast-follow only if it doubles). The only
routing change: `handleKbKey`'s targets move from imperative `SidebarView`
methods to the `@Observable` view-model bindings + `TreeController` commits
(the `KbNav.swift` pure fns are reused verbatim).

Every key preserved with no loss:
- `↑↓` / `Ctrl-N/P` / `j/k` → `kbMove`; `←→` / `h/l` / `Tab` → `kbJumpWS`.
- `Enter` → `kbCommitLift` (if lifted) else `kbActivate` (→ #66 dance).
- `Space` → `kbToggleLift`; `Esc` → `kbCancelLift` / leave-search.
- `s` → enter-search (focus the SwiftUI field via `@FocusState`);
  `t` → **enter tag-manage** (`TagEditPanel`, a host-side keyable NSPanel —
  unchanged; the SwiftUI content is not first responder for it);
  `m` → context menu.
- Search sub-mode: nav/commit keys intercepted by the monitor (incl.
  `Ctrl-N/P` + `Tab`), text/IME/⌫ pass to the SwiftUI field, gated on
  `isComposing`.

## 5. sill co-dev (the required extensions)

**sill-A — `ThemedTextFieldView` binding (T1)** *(required; also closes
sill deferred #17 — verified the bridge exposes none of these today)*.
Surface through the `NSViewRepresentable`: `onChange`, `onReturn`,
`onEscape`, `onMoveUp`, `onMoveDown`, `onFocusChange`, a controlled
`text: Binding<String>`, and a focus binding (`@FocusState`-compatible).
All already exist on the underlying AppKit `ThemedTextField` (verified) —
this only forwards them + reconciles the seed-once text model with a
controlled binding (push model→field only while not first responder).

**sill-B — glyph vendor (resource-only, T5)**. Curl `spiral` (upstream) +
GAP-A slugs; author + vendor the 6 custom tiling SVGs. No loader change
(resolves by name from `Bundle.module`). **Placement (resolved)**: vendor
into **sill resources** alongside Phosphor. An icon library carrying
glyphs a given consumer doesn't all use is normal (Phosphor already ships
~60 facet uses a subset of); the custom tiling SVGs follow Phosphor's
convention and cost only resource bytes. A load-from-caller-bundle sill API
is **not** introduced for the pilot (would be net-new sill surface for no
pilot benefit).

**Module wiring**: `FacetView` currently links **only** sill `Palette` /
`PaletteKit` / `Effects` (verified — *not* `ConfigSchema`, which is a
`FacetCore`/`FacetApp` dep, and *not* `ThemeKit`/`ThemeKitUI`). Add sill
product **`ThemeKitUI`** to the `FacetView` / `FacetViewTree` target deps in
`Package.swift` (pulls `ThemeKit`, `ListCore`, `PaletteKit`, `Palette`,
`Effects`, `Motion`, `PixelArt`, `GridCore` transitively). First SwiftUI
surface in `FacetViewTree` — View-layer only, respects the 3-layer rule.

## 6. Out of scope / fast-follow

- **T3 `dropTargetValidator`** — top fast-follow (the one gap with a
  visible UX cost). Thread `validate:` into `resolveDropTarget` /
  `dragCandidates`.
- **T2 WindowShell** (borderless+resizable / runtime wantsKey /
  canBecomeMain) — separate later slice.
- **T4 Color bridge**, **T6 slug→SwiftUI `Image` helper**, **T7 row
  anatomy extension** — only if implementation proves them needed.
- **`performSwap` header-swap** — degrade-only; revisit via a sill swap
  mode if dogfood misses it.
- **Adapter-layer SF-spec remap** (context menus) — F2 / menu migration.
- grid / rail / menus / badges / rename / thumbnail-grid — F2.
  (board-band dropped — retired with the board layer, `t-0sbm`.)

## 7. Risks

1. **#66 activation/key dance** is NSPanel/NSApp-coupled and stays
   host-side — the single biggest risk. `onActivate` must call
   `exitActive(restore:false)` **before** focus, exactly as today
   (verified invariant at `SidebarView+KbNav.swift:292` /
   `SidebarView+Drag.swift:136`).
2. **Key routing**: preserved by keeping the global monitor host-side
   (§4.8); the risk is reduced to wiring `handleKbKey` targets to the
   view-model. The host panel must be key (facet's `enterActive` satisfies
   this).
3. **Controlled-text vs seed-once** reconciliation in T1 (clobbering live
   typing) — the highest sill-side risk.
4. **Loading skeleton + optimistic-highlight timing**. Skeleton is a
   host-side overlay (§4.1) whose show/clear timing (`loadingWantsActive`
   at the skeleton→content transition) must be re-driven from a
   content-ready signal instead of the old string `signature`. The
   optimistic-highlight hold (0.85 s `optUntil`, wins the backend
   focus-assert race) moves into the **view-model `@State`**. Both must be
   reproduced explicitly, not dropped.
5. **Partial migration**: `apply()` feeds SwiftUI tree AND still-AppKit
   grid/rail — keep the projection intact, change only the tree push.
   (Was: "…grid/rail/board-band — keep the projection + board feed intact" —
   board-band and the board feed were removed with the board layer, `t-0sbm`.)
6. **Panel-move / tilting drag-ghost** — `win.performDrag` and the
   overflow drag-card have no SwiftUI equivalent; panel-move stays AppKit,
   drag chrome becomes sill's built-in ghost (title + count capsule).
7. **30 Hz palette animator vs re-flatten** (§4.6): the theme animator
   must update only the palette environment, never rebuild `[ListItem]`.
   If flatten is accidentally coupled to the palette tick, the whole list
   diffs 30×/s. Verify the animator path touches colour only.

## 8. PR structure & land order

```
sill-B ─▶ facet-1 ─▶ facet-2 ─▶ sill-A ─▶ facet-3
(glyph)   (render)   (DnD)      (T1)      (search)
```

- **sill-B** glyph vendor (unblocks facet-1 icons).
- **facet-1** tree render + kb-nav + icons + palette injection + skeleton
  overlay (SF→Phosphor name-map). The seam's core proof. ⚠️ **Not a
  standalone merge**: Task 8 removes `SidebarView` from the view hierarchy as
  the hosting view takes over, so its `mouseDown`-driven DnD and its
  `update()`-driven search filter go **dead** — a facet-1-only merge would
  ship a DnD-/search-dead tree to `main` on the daily-driver WM.
- **facet-2** DnD (`onDrop` → commits; chunk-drag section reorder).
- **sill-A** T1 binding (unblocks search; closes sill #17).
- **facet-3** search (`ThemedTextFieldView`).

**Merge unit = A (トミー 2026-07-06).** The five slices above are the
**development / local-commit order**, NOT five separate merges to `main`.
facet-1 + facet-2 + facet-3 land as **one squash-merge** so `main` never
sees a tree with dead DnD or search on the daily-driver WM. (sill-B and
sill-A remain their own separate sill-repo PRs.) The PR body states the
bundled scope + names that facet-1 alone would have regressed DnD/search.

Each PR: co-dev ritual — `../sill` path-dep during dev → `swift build`
green → swap back to url + new SemVer floor → re-pin `Package.resolved` →
single PR, **no path-dep left on main**. facet PRs carry the
`SetStatus-task` footer for `t-tsxg`. Quality-first / phased / interruptible
(commit locally freely; push waits for トミー's OK).

## 9. Success criteria (completion condition)

The **facet view `tree` + search** run on SwiftUI/sill, each check
objectively verifiable:

1. **Render parity** — for a fixed workspace/section fixture, the SwiftUI
   tree shows the same sections, rows, badges, and active-section
   highlight as the AppKit tree (side-by-side).
2. **DnD commits** — the pilot's four DnD gestures (window `applyMove`,
   section `reorderSection`, degrade `moveWindow`, panel-move) each fire
   the **identical `TreeController`/backend call** for **both** mouse and
   keyboard drag on the same target (`performSwap` is unwired, §2.4a).
3. **Keyboard-nav** — cursor ≠ selection preserved; `↑↓/hjkl/Enter/Space/
   Esc/Tab/Ctrl-N-P/s/t` all dispatch as in §4.8; **#66 same-app focus**
   succeeds (activating a same-app window row focuses it).
4. **Search** — live-filter, Escape-clear, clear-×, IME compose, and
   ↑↓-nav-into-results all work.
5. **Theming** — all palette presets render; a theme switch re-colours
   without rebuilding the item array (§4.6).

Meeting 1–5 = **seam confirmed** → unblocks F2 + cross-app rollout.

## 10. Testing

- **Pure logic stays green**: `KbNav`, `fuzzyMatch`, `FilterProjection`,
  the composite-ID mapping, and the view-model flatten
  (`[ProjectedSection]` → `[ListItem<ID>]`) are unit-testable in
  FacetCore/view-model without SwiftUI. sill's `ListCore` selection/drop
  math is already unit-tested — facet inherits that net.
- **`swift build` must pass** each phase (CLT bar; XCTest via Xcode/CI).
- **GUI verification — host consent required for the load-bearing checks.**
  A **Tart VM cannot verify DnD / #66 / kb-focus**: guest window-management
  candidate count is 0 (memory `[[facet-vm-ax-csreq-grant-and-mgmt-limit]]`),
  so the VM path is scoped to **render + theme only**. Success-criteria
  2 (DnD commits) and 3 (#66 focus) **must** run on the host (with トミー's
  per-run consent), driven by the closed-loop CLI + log protocol.
