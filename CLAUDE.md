# CLAUDE.md

Guidance for working in this repository.

## Terminology

All UI / config / code terminology follows
[`docs/glossary.md`](docs/glossary.md) — use the canonical names
(`FacetCore`, `FacetAdapterNative`, `WindowBackend`, `mac desktop`,
`facet workspace`, `facet view`, `lens desktop`, `AX target`, `pal`,
`loading skeleton`, …), **not** the `Don't call it:` synonyms.
The core concepts are kept strictly apart — hierarchy
**mac desktop (typed) > section > window**: **mac desktop** (= macOS
native Space, TYPED `workspace` | `lens` via `[desktop.N]`; code
`MacDesktops` / `DesktopMeta` / `[[desktop.N.section]]`, each a workspace
SPATIAL cell now — t-ec9s), **facet workspace** (facet's window grouping;
`WorkspaceCatalog`), **facet view** (UI: `tree`/`grid`/`rail`), **lens
desktop** (a `[desktop.N] type=lens` mac desktop: ALWAYS-ON match+layout tile
with non-matching windows anchor-parked, tree-only; t-0sbm — this replaced the
retired browser-tab **board** layer, t-wrd2/#368 → removed t-0sbm). The former
**section-lens** `lens` — a cross-workspace VIEW filter activated by `facet
lens NAME` — was retired t-ec9s; `lens` now means ONLY the lens desktop (the
auto-tag-on-match need its `apply` served moved to `[[rule]]`).
Apple's own SLS / `NSWorkspace` API names stay verbatim.
Adding or renaming a term lands in the same PR as the code change.

## What this is

`facet` — Swift workspace + window manager for macOS. Multiple
views (`--view tree|grid|rail`), native AX/CGS backend
(`FacetAdapterNative`, sole backend since v2.0.0). SIP-on,
public API + AX only. Swift 6, macOS 26+.

## Shared libraries (atelier)

facet は swift app family の共有ライブラリに乗る（plan
[atelier](https://github.com/akira-toriyama/atelier)）。かつて facet の
theme が family の参照実装だった（北極星＝「facet の theme を真似て」を
二度と言わない）が、Phase V でその theming は **sill** に抽出され、facet
自身も**共有 lib 側を消費する**側になった。共有 lib が持つ責務は
**再実装せずライブラリ側を拡張**する。モジュール → target の正確な配線は
[Package.swift](Package.swift) を正とする。

- **[sill](https://github.com/akira-toriyama/sill)** — 共有 theming /
  config / CLI 基盤。facet が消費するもの:
  - `Palette`（pure・AppKit-free）— `canonical(_:)` = 有効な `--theme=`
    名の単一ソース。`FacetCore` の no-AppKit 則を破らない。
  - `PaletteKit`（`@MainActor`・`ResolvedPalette`）— `pal` var の実体
    （[Sources/FacetView/Palette.swift](Sources/FacetView/Palette.swift)
    で re-export）。preset（`ThemeSpec`）も sill 側。
  - `Effects` — view の視覚効果（border 等）。
  - `ConfigSchema` — 1 つの宣言的 `Spec` が config.toml の decode +
    `config --emit-schema`（taplo 補完）+ `config --validate` を駆動
    （sill 1.29.0 bridge・t-0029）→ 3 者が drift しない。
- **[swift-toml-edit](https://github.com/akira-toriyama/swift-toml-edit)**
  — family 唯一の TOML 実装（`Toml` module）。元は sill in-tree だったが
  0.11.0 で独立 repo 化・`import Toml` は不変。facet は config パースに使用。

**自己完結しない — 共有候補は sill に PR を模索**: app 単独で実装する前に
「2 つ以上の app で冗長になりそうか」を問い、そうなら sill への PR を
検討する（過剰共通化はしない・zero-debt ≠ 全部共有）。

## Build / run

```sh
swift build                # compile (works on CommandLineTools)
swift test                 # tests — needs Xcode (XCTest); fails on CLT
.build/debug/facet         # raw client (use ./run.sh for the .app bundle)
```

`swift test` needs Xcode — XCTest isn't in CommandLineTools (`no such
module 'XCTest'`). With Xcode installed (`xcode-select -p` →
`Xcode.app`), `swift test` runs locally (915 tests, ~2.4 s); CI runs it
too ([build workflow](docs/architecture.md)). On a CLT-only box,
`swift build` is the bar and CI covers XCTest. (Don't `xcode-select -s`
to switch the global toolchain mid-task — borrow Xcode per-command with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
if CLT is the active default.)

`@main enum FacetApp` lives in
[Sources/FacetApp/Main.swift](Sources/FacetApp/Main.swift) (NOT
top-level code in a `main.swift`) so XCTest's executable-target
`@testable import` keeps working once tests land. **Don't reintroduce
a `main.swift` file** — the `@testable import` would break.

### Debugging facet (the agent run loop)

facet is a live GUI agent, so verifying a change means running the
real app and watching it. The loop an AI agent (Claude Code) should
use:

```sh
./run.sh          # build release → kill any running facet → launch Facet.app
./stop.sh         # kill all facet instances (release / dev / raw SwiftPM)
FACET_DEBUG=1 .build/release/facet 2>&1 | tee /tmp/facet-bug-$(date +%H%M%S).log &
                  # foreground server with verbose log (FACET_DEBUG
                  # mirrors to stderr; no --debug flag since #114, it's
                  # env-var-triggered; timestamped so runs don't pile
                  # up); read the file directly to inspect
```

- **The agent may run `./stop.sh` / `./run.sh` / `swift build`
  freely while debugging** — it doesn't need to ask each time. The
  human pilots the panel (clicks / drags / keys) and reports; the
  agent drives build + relaunch. (This pairs with: the agent reads
  `/tmp/facet*.log` directly rather than asking for pasted output.)
- **Host-PC GUI verification needs consent; a Tart VM is free.**
  Building, relaunching, and reading logs are always fine — but
  *driving facet's GUI on the host to verify it* (launching panels,
  `screencapture`, `osascript`-driven clicks — it takes over the
  screen + key focus) **requires the human's OK first**. In a **Tart
  VM** (clean-environment testing — References → *Sandbox / VM
  testing*) verify freely, no consent needed. Two follow-ons for any
  **host** GUI run: (1) when done, **return the working window — the
  VSCode / Claude Code window driving the task — to a clear, visible
  position** so the human can resume; (2) keep a single unattended
  automated GUI sequence to **~10 minutes** as a guideline —
  checkpoint with the human rather than running longer.
- **GUI bugs: observe before theorising.** A screen recording can
  be frame-extracted (`ffmpeg -i in.mov -vf fps=3 f_%02d.png`) and
  the PNGs read directly; `FACET_DEBUG` logs every Controller / Adapter
  hot-path event. Cursor shape + panel position in a frame tell you
  whether a click hit its target — facts, not guesses.
- **When ≥2 fixes haven't worked, isolate in a sandbox.** A pure-
  AppKit `.executableTarget` (no FacetCore / View deps) that opens
  the offending construct in several variant configs A/B-tests the
  OS behaviour without facet's noise. The worked example was a
  `panel-sandbox` executable target (8 `NSPanel` `styleMask`
  variants in a 4×2 grid) — how the chevron → `.resizable` switch
  was found. See References → *Debugging methodology*.

## Non-obvious constraints — read before editing

### Layer rules (the spine of the project)

- **3 layers are non-negotiable**: `FacetCore` is pure logic
  (CoreGraphics OK, NO AppKit / NO backend / NO OS interaction).
  `FacetAdapter*` wraps a backend (AX/CGS today) and is the
  *only* place those types appear. `FacetView*` is GUI-only.
  Crossing layers always means there's a missing protocol.
- **Backend-specific types stay inside their adapter module**.
  Conversion to the backend-neutral
  [Sources/FacetCore/Models.swift](Sources/FacetCore/Models.swift)
  types happens at the seam. Views and controller must never see
  adapter-internal types.
- **Views talk to the `WindowBackend` protocol, never to a
  concrete adapter directly**. This is what kept the Phase ε rift
  retirement a one-module swap, and is what lets future adapters
  land without touching view code.

### View-layer contracts — keep them intact

- **`pal` is a `@MainActor` module-level var** — defined in sill's
  PaletteKit (`ResolvedPalette`) and re-exported through
  [Sources/FacetView/Palette.swift](Sources/FacetView/Palette.swift).
  Every view file references `pal.foreground`, `pal.muted`,
  `pal.primary`, etc. in dozens of places. Don't rename the `pal`
  var to `Theme.current` or similar; it would touch ~hundreds of
  view-side lines for zero behavior gain. (The Tailwind-style field
  names — `foreground` / `muted` / `primary` / … — come from sill's
  Phase-V `ThemeSpec`; the `pal` var name itself stays.)
- **Theme presets live in sill, not facet.** `ThemeSpec` presets
  (`.terminal` / `.dracula` / `.system`, …) are pure `Sendable`
  values (UInt32 hex). The `@MainActor` constraint is on the
  *resolved* side (`ResolvedPalette` / `resolve(_:)`) because
  `NSColor` isn't `Sendable` under Swift 6 — don't resolve a
  palette to `NSColor` off the main actor.
- **Window titles are AX-resolved**. `AXTitles.resolve` reads
  `kAXTitle` directly, short-TTL cached, only off-main. Don't
  assume `Window.title` is populated by the backend alone.
  (Memory: [[window-titles-ax-resolved]].)
- **`FlippedClipView` is used for every scroll view from day
  one**. Non-flipped `NSClipView` causes intermittent grip-drag
  failures (memory [[grid-branch-grip-intermittent]]). Don't wait
  to "hit the bug" before adopting it.
- **The drag-state lifecycle is a backend round-trip flag**, not a
  mouse-event flag. Don't clear it on `mouseUp` — clear it when the
  backend confirms the move. Memory:
  [[grid-drag-state-lifecycle]].

### M2 / M5 boundaries

- **Native adapter is the sole backend** (v2.0.0 retired rift).
  M5 complete: Phase α (workspaces + focus + AX
  events), β (anchor hide, closeWindow), γ (BSP + stack tiling,
  AX-role auto-float for
  sheets / dialogs / palettes; tiling CLI = `facet workspace
  --layout NAME` / `--retile` plus `facet window --toggle-float` /
  `--toggle-orientation` / `--cycle-stack next|prev` — reshaped to
  the subject-verb form by Theme C #81/#82), δ (display
  reconfigure), ε (rift retire) all shipped. See `facet --help`
  and [docs/architecture.md](docs/architecture.md) for the contracts.
- **AX helpers live in `FacetAccessibility`** (extracted at M5;
  sole consumer now is `FacetAdapterNative` after Phase ε
  retired rift). `AXFocus`, `AXTitles`, `Focus.assert` /
  `withRetry`, `AXGeom` (window lookup / position / size / close
  button), `Displays` (screen-containing-point), and
  `WindowEventObserver` (per-app AX subscription) all live here.
  New AX code goes here unless it's truly backend-specific.
- **Per-mac-desktop workspaces** (memory
  [[facet-per-native-space-ws]]): each mac desktop (native macOS
  Space) keeps an independent `WorkspaceCatalog`. `NativeAdapter`
  parks the active catalog by mac desktop id and swaps in the
  destination mac desktop's in `refreshCatalog`. The active mac
  desktop id + Mission-Control ordinal are read via **read-only**
  private SkyLight (`MacDesktops` in
  `FacetAccessibility`: `SLSGetActiveSpace` /
  `SLSCopyManagedDisplaySpaces`, dlsym-bound — Apple's SLS symbol
  names stay as-is). **READ-only is the rule** — facet never moves a
  window across mac desktops (that needs SIP-off; see
  [[facet-hide-fork-scope]] 手法4). SkyLight unavailable →
  `activeMacDesktopID == 0` → one shared catalog (pre-feature
  behaviour). `[[desktop.N.section]]` config keys by ordinal; catalog
  state is session-only (never persisted), rebuilt from live windows on
  restart. **A mac desktop may be TYPED** — `[desktop.N]` is a SINGLE
  table with `type = "workspace" | "lens"` (t-0sbm; one ordinal = one
  desktop = one type; a sections-only config implies `workspace`). A
  **lens desktop** carries `match` (required) + `layout` /
  `show-non-matching` / `label` directly on the table: while that mac
  desktop is active, facet ALWAYS tiles the matched windows with the
  lens `layout` and anchor-parks the rest (`applyIsolatePark`; flat —
  `effectiveWorkspaceList` seeds exactly ONE workspace). Lens desktops
  are TREE-ONLY: `--view grid` / `--view rail` there loud-reject. See
  the glossary `### lens desktop` +
  [docs/architecture.md](docs/architecture.md) "The typed-desktop
  layer". (The former board layer — `[[desktop.N.tab]]`, `facet board`,
  the switcher bands — was retired by t-0sbm.) **Opt-in rule**: any
  `[[desktop.N.section]]` OR `[desktop.N]` block makes facet
  manage ONLY configured mac desktops — others are hands-off (no
  adopt/park, empty `workspaces()` → Controller's empty-list guard
  hides the panel). No `[[desktop.N.section]]` / `[desktop.N]` at all
  → every mac desktop managed with the global default (`FacetConfig.isMacDesktopManaged`
  gates on EITHER form).
  **A workspace section may be named from config via an optional `label`**
  (§A / t-0018 reversed the old "never named from config" rule; the old
  `[desktop.N]` by-name seed stays retired). Every `[[desktop.N.section]]`
  is a workspace SPATIAL cell now (t-ec9s dropped the section `type` /
  `match` / `apply`); a non-empty `label` names the workspace, an empty /
  absent `label` leaves it UNNAMED — displayed by its 1-based index (§B
  retired the emoji auto-name pool `WorkspaceNaming`; all section headers
  compose via `sectionDisplayLabel(index:label:)` → `index` or
  `index (label)`, §D). The `label` is OPTIONAL (the `unassigned` receptacle
  too); within one mac desktop a non-empty `label` must be unique (loud
  warn + first-wins; empty labels may repeat — name resolution targets only
  labeled workspaces, unnamed ones are index-addressed). Runtime
  `facet workspace --rename` still overrides. (Identity is keyed on the
  stable section id, not the label — see [[facet-pivot-section-lens-model]].)
- **Loading skeleton is CLI-triggered, not auto** (`facet --view tree
  --loading MS`): macOS exposes no pre-mac-desktop-switch hook, so
  facet can't detect a switch early enough to mask the flicker.
  Instead an external tool (chord) fires `--loading` *before* the
  switch keys; `Controller.showLoading` paints `SidebarView`'s
  skeleton, held until the next *different* content signature loads
  (auto-clear) or `MS` elapses (cap). Don't reintroduce a
  backend-event / activeSpaceDidChange auto-trigger — it's always too
  late (the mac desktop commits ~0.7s post-keypress). Memory:
  [[facet-per-native-space-ws]].
- **A user-hidden window gives up its tile slot** (Cmd+H / Cmd+M).
  `WorkspaceCatalog.reconcileHidden` detaches an `isOnscreen=false`
  managed window from its layout so the neighbours reclaim the slot,
  keeps it in `windowMap` (WS assignment + marks survive), and
  re-attaches it at the tail when it returns on-screen. facet's own
  parking uses the on-screen anchor sliver (`isOnscreen` stays true),
  so only a genuine user hide triggers this — never facet itself. The
  tree shows the window dimmed with a `hidden` badge; clicking it
  restores (`WindowBackend.revealWindow`: unhide app + un-minimize +
  focus). Detection is AX-event-driven (≈0.3s) with the 2s poll as a
  safety net, behind a two-tick gate that ignores the Space-switch
  off-screen transient. Memory: [[facet-window-policy]].
- **Bundle id is `com.facet.app`** (M2 done). See
  [package.sh](package.sh) at repo root. The id keys the TCC grant
  and self-signed cert identity — don't change it.

### CLI surface

- **Symmetric per-view ops**: ``--view NAME``,
  ``--hide NAME``, ``--toggle NAME``. Adding a new view
  (dock, palette, hover-bar, …) only needs an entry in
  ``Main.canonicalViews`` + matching cases in
  ``Controller.dispatchView/Hide/Toggle``. Keep this pattern —
  don't reintroduce per-view bespoke flags.
- **``facet section`` addresses ANY section (workspace, unassigned, OR a lens
  desktop's synthesized section) by its 1-based tree-order index or its label** —
  the unified addressing layer. ``--focus N|LABEL`` (switch workspace / — §G —
  focus an unassigned OR lens-desktop section's FIRST window via the unified
  ``focusFirstWindow(inSectionID:)``, since the section-lens ACTIVATE concept was
  retired t-ec9s; resolves via ``addressableSections()`` reading ``lastSections``).
  ``--rename N "label"`` sets the display label at runtime (§E): workspace →
  catalog ``renameWorkspace``; unassigned (§G) → session-only
  ``Controller.sectionLabelOverride`` (id-keyed, applied at the projection seam by
  the pure ``applyLabelOverrides``); empty → revert. On a lens desktop ``--rename``
  is a loud reject (its sections are match-synthesized). ``--match N "expr"``
  retargets a lens desktop's match (session-only ordinal-keyed
  ``lensDesktopMatchOverride``, D6; pushed to the adapter's ``setLensDesktopMatch``
  so display + park stay in lock-step). Identity stays on the stable section id.
  Session-only: reset on relaunch, NOT on ``facet reload``. GUI twin = the tree
  header right-click ``Section ▸ Rename`` (``beginSectionRename`` →
  ``SectionRenamePanel``) + ``Edit match`` (``beginSectionMatchEdit``, lens desktop).
  Wire ``section-rename:<index>:<label>`` splits once so a label may contain ``:``.
- **The two-world gate — what a lens desktop refuses** (``LensDesktopGate``
  in ``FacetCore``, the single home; ``Controller`` consults it once before
  the DNC ``switch``, and again in ``dispatchView`` / ``dispatchToggle``):
  - **TREE-ONLY** — `--view grid` / `--view rail` (and their toggles) are a
    loud ``setError`` no-op: a lens desktop's membership is dynamic, so there
    is no fixed picture to thumbnail. The tree renders its 1–2 synthesized
    sections (``FilterProjection.projectLensDesktop`` — matched + optional
    non-matching holding; t-ec9s decoupled it from the config ``DesktopSection``).
  - **Workspace-SET + active-workspace verbs are refused too** — ``workspace
    --add`` / ``--remove`` / ``--rename`` / ``--move`` / ``--focus``,
    ``workspace --layout``, and ``section --rename``. A lens desktop is FLAT
    (``effectiveWorkspaceList`` seeds exactly ONE workspace), so they have
    nothing to act on — and ``--add`` actively breaks the N=1 invariant the
    anchor-park scope relies on.
  - **Tile REFINEMENT is deliberately NOT gated** — ``--retile`` / ``--balance``
    / ``--rotate`` / ``--mirror`` refine the tiled set within the same layout
    mode, so they take effect and persist exactly as on a workspace desktop.
    Window verbs, scratchpad verbs, tags, ``section --focus`` and ``section
    --match`` work there too. Don't "tidy" these into the gate.

  (``facet board`` was removed with the board layer, t-0sbm.)
- **The tree opens in keyboard-nav (active) mode directly** —
  there is **no ``--active`` modifier** (it was folded into
  ``--view tree`` itself; the flag, the ``view:tree+active`` DNC
  mod, the ``activeFlag`` parse + its two validations were all
  removed). ``--view tree`` and a toggle-on (``--toggle tree``)
  call ``enterActive`` — flip activation policy to ``.regular`` +
  take key — so ↑↓ / Enter / search (``s``) / tag-manage (``t``)
  work the instant the panel appears (Spotlight-style; a hotkey
  jumps straight in). **#66 is preserved by handing key BACK
  before focusing**: acting on a row (mouse click in
  ``SidebarView.mouseDown`` → ``handleClick``, or Enter →
  ``kbActivate``) calls ``exitActive(restore: false)`` FIRST, so
  facet relinquishes key and a same-app window focuses via public
  AX (``KeyablePanel.canBecomeKey`` is still gated to ``wantsKey``;
  a click never leaves the panel holding key *while* focusing).
  The panel settles back to passive — the resting state — after
  any interaction. The ``Desktop N`` header right-click (Search /
  Manage tags → ``enterSearchFromMenu`` / ``enterTagManage``)
  still self-activates. **facet boots agent-only** — no panel at
  launch (the ``default-view`` config key was removed): a tree
  appears only via an explicit summon (``--view tree`` / a chord
  hotkey), which always ``enterActive``s, so facet never steals
  focus at launch *and* a shown tree is never keyboard-dead. Grid
  is always key/active by construction; the rail is always
  passive. Memory: [[facet-same-app-window-focus-skylight]].
- **``--edge top|bottom|left|right`` is a modifier too** (M9-3),
  only meaningful with ``--view rail`` (becomes ``view:rail+edge:NAME``
  on the DNC); ``--edge`` without ``--view rail`` is a loud
  ``exit 2``. It picks which screen edge the rail's strip docks
  against (`mac desktop`-independent); the strip axis drives which
  arrows browse (top/bottom → ←/→, left/right → ↑/↓). Config seed
  is ``[rail] edge`` (silent clamp→bottom). The strip header stays a
  horizontal band on every edge (no text rotation — a vertical stack
  of label/thumbnail cells).
- **Strip/hero split is `[rail] strip` (% of the SHORT screen
  edge)**, a CAP on the thumbnail scale; the hero fills the rest.
  Short-edge-based (NOT the cross axis) so it stays balanced in any
  orientation / on any display size — the cross-axis fraction over-
  thickened the strip in portrait (cross = the long edge). The
  thumbnails are **justified**: they grow so the shown cells fill the
  run with one ``railCellGap`` between them (even, tight gaps, ≈ full
  width), capped by ``strip``; only when too few cells would exceed the
  cap does the group stop growing + centre with end margins. The band
  then **auto-fits** the actual thumb (so ≤ ``strip``%). ``[rail]
  cells`` is the **upper bound** on cells shown (``visible =
  min(cells, n)``); the rest rotate. No odd-forcing — the active is
  pinned to centre via offset 0 regardless of parity. Pure helper
  `railScaledPads` (short-edge-scaled gaps) lives in FacetCore. Memory:
  [[facet-rail-decisions]].
- **The rail is an active-centred CAROUSEL** (2-b): the active
  workspace is pinned to the strip centre, the rest fan out
  circularly, and the browse arrows ROTATE the strip (centre = the
  selection; Return / click switches to centre + closes). More than
  ``[rail] cells`` workspaces rotate through with a both-ends peek —
  there is **no scroll**. Geometry is pure (`railBands` /
  `railCarouselOffsets` in FacetCore, unit-tested). This replaced the
  M9-4 fit-or-scroll model; don't reintroduce `scrollOffset` /
  `railScrollToShow`. Design: memory `[[facet-rail-decisions]]`.
- **No bare-flag tree aliases**. ``--show`` / ``--hide`` /
  ``--toggle`` standalone were dropped — every view op specifies
  NAME explicitly (and ``--active`` was removed entirely — see the
  tree-opens-active note above). Keeps the canonical form
  unambiguous (no "is ``--hide`` short for ``--hide tree`` or
  is it the legacy bare verb?" surface area). Shorthand is the
  user's shell-alias problem, not facet's. Reintroducing bare
  flags also means reintroducing per-view dispatch ambiguity
  when a new view (dock, palette, …) lands.
- **``--view NAME`` is idempotent (show)**, not toggle. To
  toggle, use ``--toggle NAME``. Do not regress to toggle-on-show.
- **Typo rejection is loud**: unknown view / theme names
  ``exit 2`` with a stderr message. Silent fallback is
  deliberately not offered — typos should fail visibly.
- **State-changing scripts honour ``--dry-run`` and tee a log
  by default**. Any script that mutates the user's environment
  (screen recording, mouse events, network posts, file writes
  outside the repo) ships:
  - ``--dry-run`` — print what would happen instead of executing
    (clig.dev *robustness*: make state changes preview-able).
  - tee of stdout/stderr to ``/tmp/<script>.log`` *on by default*
    so reruns + agent inspection are easy; ``--silent`` opts
    out. The inverted polarity (log-on by default, not
    ``FACET_DEBUG``-gated like the app) reflects the different
    audience: scripts are run rarely + interactively, the app
    runs continuously.

  The application CLI itself (``facet --view *`` etc.) is
  idempotent / DNC-broadcast and doesn't need ``--dry-run``;
  its logging is ``FACET_DEBUG``-gated for the opposite reason
  (long-lived server, default-quiet stderr). This rule applies
  to repo-local automation, not to the app surface.

### Logging

- **`Log` lives in `FacetCore`** so both adapters and view modules
  can call it without crossing layer rules. Two functions:
  ``Log.line`` (always on, for end-user-visible operational events
  like AX focus mismatches) and ``Log.debug`` (gated by the
  ``debugMode`` global, set from the ``FACET_DEBUG`` env var at
  startup — run.sh sets it; brew / raw ``open Facet.app`` stays quiet).
- **Both write to `/tmp/facet.log`**; ``FACET_DEBUG`` also mirrors to
  stderr so foreground users see events live and bug reports can
  capture them with ``2>&1 | tee bug.log``. Non-debug runs stay
  quiet on stderr so a backgrounded ``facet &`` doesn't pollute
  the launching shell.
- **Use ``Log.debug`` liberally** in Controller / Adapter /
  EventSource hot paths. It costs one bool check when disabled.
  Skip view-side handlers (mouseMoved etc.) — they fire too often
  to be useful even with the gate.

### Configuration

- **`config.toml` at the repo root is the source-of-truth template**.
  Users `curl` it into `~/.config/facet/config.toml` (see
  [README.md](README.md) Install section). **The app only reads it**
  — never writes, never auto-generates an example, never persists
  runtime overrides to disk. Don't reintroduce
  `FacetConfig.writeExampleIfMissing()` or a UserDefaults theme
  store; both were removed deliberately to keep the file the only
  thing the user has to look at to know what facet will do.
  Memory: [[config-default-behavior]].
- **The ONE sanctioned write to config.toml is startup `auto-promote`**
  (t-hdxb, opt-in). With `[config] export-path` set, facet *auto-exports*
  a live **snapshot** of the effective config to that separate file on
  every session edit (rename / lens match / layout / tag vocab) — a
  surgical write via swift-toml-edit that leaves config.toml untouched.
  With `[config] auto-promote = true`, the NEXT launch promotes a snapshot
  that is strictly newer than config.toml onto it (overwrite + load), so a
  hand-edit between sessions still wins (mtime guard). This is the sole
  carve-out from "never writes config.toml": it happens once, at startup,
  only on opt-in, and only from a newer snapshot. `reloadConfig` / the
  watcher / `config --validate` still never write. `FacetConfig.load`
  stays read-only; the promote lives in the separate
  `bootstrapWithAutoPromote`. The snapshot writer is `ConfigSnapshot`
  (pure) driven by `Controller.markConfigDirty`. Memory:
  [[config-default-behavior]].
- **Runtime CLI overrides are session-only**.
  `facet --theme cute` swaps the palette in memory but does NOT
  persist. To make it stick, edit `~/.config/facet/config.toml`.
  Same goes for `--view ...` (toggles, doesn't change default).
- **All TOML keys clamp out-of-range / unknown values to defaults**
  rather than rejecting. A typo can never break the layout — the
  user just gets the default for that one key. The `effective*`
  accessors on `FacetConfig` are where the clamping lives; always
  read through them, never the raw Optional fields.
- **Section-scoped > bare top-level when adding TOML / CLI surface**.
  New TOML knobs go under a named ``[section]`` — even if the same
  key (``color``, ``size``, …) repeats across sections — over a
  bare top-level key that other sections implicitly inherit. Each
  section then reads as a self-contained unit (grep ``[section]``
  shows every knob that affects it). Same rule for new CLI options:
  scope under the verb / subcommand they affect over a global
  top-level flag. *want / better*, not *must* — relocating an
  existing bare key into sections is an acceptable breaking change
  when the readability win is clear, but don't refactor for the
  rule alone. Example — preferred:

  ```toml
  [foo]
  color = "red"
  length = "short"

  [bar]
  color = "red"
  size = "xl"
  ```

  Avoid:

  ```toml
  color = "red"

  [foo]
  length = "short"

  [bar]
  size = "xl"
  ```

### Workflow

- **Don't push without explicit OK**. Quality-first phased
  workflow (memory [[grid-view-work-style]]). Commit locally
  freely; pushing / merging waits for トミー's go.
- **PR-based, no direct main push** (since v1.0.0). `main` has
  branch protection: a PR is required to merge, `build` + `lint`
  status checks must be green (strict / up-to-date), force-push
  and deletion are blocked. `enforce_admins` is off, so the
  maintainer can bypass for an emergency hotfix. Flow: feature
  branch (`docs/` / `feat/` / `fix/` prefix) → push →
  `gh pr create --assignee @me` → squash-merge
  (`gh pr merge N --squash --delete-branch`). If you accidentally
  commit on local `main`: `git branch <topic>` to save it, then
  `git reset --hard origin/main`, then PR the branch. See memory
  [[pr-conventions]].
## Conventions

- **Commit messages**: gitmoji + Conventional Commits —
  `<:gitmoji:> <type>(<scope>)<!>: <subject>`. Full spec:
  [CONTRIBUTING.md](https://github.com/akira-toriyama/.github/blob/main/CONTRIBUTING.md). Enable
  the local hook: `git config core.hooksPath scripts/hooks` (script
  at [scripts/hooks/commit-msg](scripts/hooks/commit-msg)).
- **README is bilingual** ([README.md](README.md) English +
  [README.ja.md](README.ja.md) Japanese). Keep them in sync when
  user-visible behavior changes. Memory [[readme-bilingual]].
- After source edits, **`swift build` must pass** before finishing
  a turn.

## References

External material that informed facet's API / architecture
decisions — Hexagonal/CA/DDD, commit conventions, CLI design,
Swift/Apple, macOS platform, GitHub/CI, packaging, sandbox/VM.
Moved out of this file to keep it lean: see
[docs/references.md](docs/references.md). Each entry carries a
`(reviewed YYYY-MM-DD)` freshness stamp (memory
`external-reference-selection`); re-check on any 6+ month gap.


## Roadmap board / task tracker

issue 運用（集約 Project「roadmap」#5・Inbox 既定 / Status フロー / `Closes #N`）は
family 共通ポリシー。正典 → https://github.com/akira-toriyama/atelier/blob/main/docs/roadmap-board.md

facet の作業タスク（バックログ・設計メモ・引き継ぎ）の**正本は private repo
[`akira-toriyama/projects`](https://github.com/akira-toriyama/projects)**（自作 furrow 製・
plain-text の `.furrow/` = JSON index + per-task markdown body）。**local clone =
`/Volumes/workspace/github.com/akira-toriyama/projects`**（furrow source =
`/Volumes/workspace/github.com/akira-toriyama/furrow`）・**運用ルールの正典はその
[`projects/CLAUDE.md`](https://github.com/akira-toriyama/projects/blob/main/CLAUDE.md)**。
`facet` ラベルで絞る: `furrow ls -l facet`（着手候補 = ready / in-progress）/
`furrow show <id>`・起票は `furrow add "…" -l facet`（**repo ラベル必須**・無いと exit 2）。
`furrow next` は actionable（next-lane = ready / in-progress かつ deps 完了）を canonical
order で出す（`-l facet` で repo 絞り・`-n` で件数制限）。Project #5 はその
公開ミラー（手動）。**repo-root の `Task.md` は 2026-06-25 に退役**し projects へ移行済み
（`furrow migrate --label facet`）。`.furrow/index.json` は furrow が機械生成＝手編集禁止・
`bodies/*.md` は手編集 OK。

**書き込み時の運用（`projects/CLAUDE.md` 正典）**: ① **共有 checkout で並行 git 禁止 —
書き込みは worktree か別 clone で**（`git worktree add ../projects-<topic> -b <branch>
origin/main`・複数の人/エージェントが同時に触るため）。② projects の `main` は **direct-push 可
だが fast-forward only**（PR 不要・push 前 `git pull --rebase origin main`・`pre-push` hook =
`git config core.hooksPath scripts/hooks` で有効化）。③ commit 前に `furrow lint`・commit 規約 =
gitmoji + conventional（`:card_file_box: chore(furrow): …`）。④ task id は **衝突しない
ランダム id**（furrow#18 で `.furrow/seq` を廃止・`t-3q17` 形式）。**furrow は開発活発なので
install せず source から使うのが安全**（常に最新挙動・install 版は stale 化する）: furrow source
= `/Volumes/workspace/github.com/akira-toriyama/furrow` を `go build -o /tmp/furrow-dev ./cmd/furrow`
（or `go run ./cmd/furrow <args>`）。**⚠️ 古い install 版（seq ベース・`furrow version` が #18 前）
だと並行 `add` で id 衝突**（実際に発生）→ source ビルド版を使う（or `go install …/cmd/furrow@latest`
で更新）。
