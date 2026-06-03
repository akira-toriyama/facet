# CLAUDE.md

Guidance for working in this repository.

## Terminology

All UI / config / code terminology follows
[`docs/glossary.md`](docs/glossary.md) — use the canonical names
(`FacetCore`, `FacetAdapterNative`, `WindowBackend`, `mac desktop`,
`facet workspace`, `facet view`, `lens`, `AX target`, `pal`,
`loading skeleton`, …), **not** the `Don't call it:` synonyms.
The 4 core concepts are kept strictly apart: **mac desktop** (= macOS
native Space; code `MacDesktops` / `[desktop.N]`), **facet workspace**
(facet's window grouping; `WorkspaceCatalog`), **facet view** (UI:
`tree`/`grid`/`rail`), **lens** (tag display set; M11-3, not yet in
code). Apple's own SLS / `NSWorkspace` API names stay verbatim.
Adding or renaming a term lands in the same PR as the code change.

## What this is

`facet` — Swift workspace + window manager for macOS. Multiple
views (`--view=tree|grid|rail`), native AX/CGS backend
(`FacetAdapterNative`, sole backend since v2.0.0). SIP-on,
public API + AX only. Swift 6, macOS 13+.

## Build / run

```sh
swift build                # compile (works on CommandLineTools)
swift test                 # tests — needs Xcode (XCTest); fails on CLT
.build/debug/facet         # raw client (use ./run.sh for the .app bundle)
```

`swift test` does NOT work on CommandLineTools-only setups (`no such
module 'XCTest'`); tests run in CI
([build workflow lands in M2 step 7](docs/architecture.md)). Locally,
`swift build` is the bar; let CI cover XCTest.

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

- **`pal` is a `@MainActor` module-level var in
  [Sources/FacetView/Theme.swift](Sources/FacetView/Theme.swift)**.
  Every view file references `pal.text`, `pal.dim`, etc. in dozens
  of places. Don't rename it to `Theme.current` or similar; it
  would touch ~hundreds of view-side lines for zero behavior gain.
- **`Palette` presets (`.terminal` / `.cute` / `.system`) are
  `@MainActor`** because `NSColor` is not `Sendable` under Swift 6
  strict concurrency. Don't try to make them ordinary top-level
  `let`s.
- **Window titles are AX-resolved**. `AXTitles.resolve` reads
  `kAXTitle` directly, short-TTL cached, only off-main. Don't
  assume `Window.title` is populated by the backend alone.
  (Memory: [[window-titles-AX-resolved]].)
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
  --layout=NAME` / `--retile` plus `facet window --toggle-float` /
  `--toggle-orientation` / `--cycle-stack=next|prev` — reshaped to
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
  [[native-window-hide-methods]] 手法4). SkyLight unavailable →
  `activeMacDesktopID == 0` → one shared catalog (pre-feature
  behaviour). `[desktop.N]` config keys by ordinal; catalog state is
  session-only (never persisted), rebuilt from live windows on
  restart. **Opt-in rule**: any `[desktop.N]` section makes facet
  manage ONLY configured mac desktops — others are hands-off (no
  adopt/park, empty `workspaces()` → Controller's empty-list guard
  hides the panel). No `[desktop.N]` at all → every mac desktop
  managed with the global default. `FacetConfig.isMacDesktopManaged`.
- **Loading skeleton is CLI-triggered, not auto** (`facet --view=tree
  --loading[=MS]`): macOS exposes no pre-mac-desktop-switch hook, so
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
  off-screen transient. Memory: [[facet-hide-reclaim-decisions]].
- **Bundle id is `com.facet.app`** (M2 done). See
  [package.sh](package.sh) at repo root. The id keys the TCC grant
  and self-signed cert identity — don't change it.

### CLI surface

- **Symmetric per-view ops**: ``--view=NAME``,
  ``--hide=NAME``, ``--toggle=NAME``. Adding a new view
  (dock, palette, hover-bar, …) only needs an entry in
  ``Main.canonicalViews`` + matching cases in
  ``Controller.dispatchView/Hide/Toggle``. Keep this pattern —
  don't reintroduce per-view bespoke flags.
- **``--active`` is a modifier**, not a verb. Only meaningful
  combined with ``--view=tree`` (becomes ``view:tree+active`` on
  the DNC). For grid it's silently ignored — the overlay is
  always key/active by construction. Without ``--active`` the
  tree panel still enables keyboard nav as soon as the user
  clicks it (PanelHost's onKeyChanged → Controller's enterKbNav);
  ``--active`` only differs by taking key focus *immediately*
  (+ flipping activation policy so the local keyDown monitor can
  fire before the user has clicked).
- **``--edge=top|bottom|left|right`` is a modifier too** (M9-3),
  only meaningful with ``--view=rail`` (becomes ``view:rail+edge:NAME``
  on the DNC); ``--edge`` without ``--view=rail`` is a loud
  ``exit 2``. It picks which screen edge the rail's strip docks
  against (`mac desktop`-independent); the strip axis drives which
  arrows browse (top/bottom → ←/→, left/right → ↑/↓). Config seed
  is ``[rail] edge`` (silent clamp→bottom); ``[rail] cells`` sets
  the carousel's viewport-full count. The strip header stays a
  horizontal band on every edge (no text rotation — a vertical stack
  of label/thumbnail cells).
- **The rail is an active-centred CAROUSEL** (2-b): the active
  workspace is pinned to the strip centre, the rest fan out
  circularly, and the browse arrows ROTATE the strip (centre = the
  selection; Return / click switches to centre + closes). More than
  ``[rail] cells`` workspaces rotate through with a both-ends peek —
  there is **no scroll**. Geometry is pure (`railBands` /
  `railCarouselOffsets` in FacetCore, unit-tested). This replaced the
  M9-4 fit-or-scroll model; don't reintroduce `scrollOffset` /
  `railScrollToShow`. Design: memory `[[facet-rail-carousel-decisions]]`.
- **No bare-flag tree aliases**. ``--show`` / ``--hide`` /
  ``--toggle`` / ``--active`` standalone were dropped — every
  view op specifies NAME explicitly. Keeps the canonical form
  unambiguous (no "is ``--hide`` short for ``--hide=tree`` or
  is it the legacy bare verb?" surface area). Shorthand is the
  user's shell-alias problem, not facet's. Reintroducing bare
  flags also means reintroducing per-view dispatch ambiguity
  when a new view (dock, palette, …) lands.
- **``--view=NAME`` is idempotent (show)**, not toggle. To
  toggle, use ``--toggle=NAME``. Do not regress to toggle-on-show.
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

  The application CLI itself (``facet --view=*`` etc.) is
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
- **Runtime CLI overrides are session-only**.
  `facet --theme=cute` swaps the palette in memory but does NOT
  persist. To make it stick, edit `~/.config/facet/config.toml`.
  Same goes for `--view=...` (toggles, doesn't change default).
- **All TOML keys clamp out-of-range / unknown values to defaults**
  rather than rejecting. A typo can never break the layout — the
  user just gets the default for that one key. The `effective*`
  accessors on `FacetConfig` are where the clamping lives; always
  read through them, never the raw Optional fields.

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
  [docs/commit-convention.md](docs/commit-convention.md). Enable
  the local hook: `git config core.hooksPath scripts/hooks` (script
  at [scripts/hooks/commit-msg](scripts/hooks/commit-msg)).
- **README is bilingual** ([README.md](README.md) English +
  [README.ja.md](README.ja.md) Japanese). Keep them in sync when
  user-visible behavior changes. Memory [[readme-bilingual]].
- After source edits, **`swift build` must pass** before finishing
  a turn.

## References

External material that informed facet's API / architecture
decisions. Kept here so the rationale survives future
contributors (human or AI) reopening the repo cold.

Subsections ordered **broad → narrow / language-neutral →
language-specific** (memory `external-reference-selection`'s
application-priority rule). Each entry carries
`(reviewed YYYY-MM-DD)` so the freshness lifecycle is visible
at a glance; re-check on any 6+ month gap, refresh the date on
re-confirmation.

### Architecture (Hexagonal / Clean Architecture / DDD)
*Language-neutral, governs whole-system structure.*

- [Hexagonal Architecture / Ports & Adapters (Alistair Cockburn)](https://alistair.cockburn.us/hexagonal-architecture/)
  *(reviewed 2026-05-21)* — the pattern facet's 3-layer split
  is literally implementing. ``WindowBackend`` protocol = a
  Port; ``FacetAdapterNative`` = an Adapter; ``FacetCore`` lives
  inside the hexagon. Clean Architecture restates this idea
  with more layers; the rosetta-stone table in
  [docs/architecture.md](docs/architecture.md) shows the mapping.
- [jasontaylordev/cleanarchitecture](https://github.com/jasontaylordev/cleanarchitecture)
  *(reviewed 2026-05-21)* — canonical CA 4-layer template
  (.NET reference for the concept).
- [sergdort/ModernCleanArchitectureSwiftUI](https://github.com/sergdort/ModernCleanArchitectureSwiftUI)
  *(reviewed 2026-05-21)* — Swift-native CA module layout. The
  Domain / Platform / Features / Application split informed the
  rosetta-stone table in
  [docs/architecture.md](docs/architecture.md).
- [tuan188/CleanArchitecture](https://github.com/tuan188/CleanArchitecture)
  *(reviewed 2026-05-21)* — second Swift-CA reference; consult
  if a fundamental restructure is on the table.
- [GitHub topic: domain-driven-design](https://github.com/topics/domain-driven-design)
  *(reviewed 2026-05-21)* — entry point for cross-language DDD
  pattern examples.

### Conventions (commit / version)
*Language-neutral, governs collaboration culture.*

- [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/)
  *(reviewed 2026-05-21)* — the commit-message spec facet's
  [docs/commit-convention.md](docs/commit-convention.md) is
  built on. ``cliff.toml`` parses ``<type>(<scope>)<!>:
  <subject>`` per this spec; git-cliff derives the next semver
  from the ``type`` field.
- [gitmoji](https://gitmoji.dev/)
  *(reviewed 2026-05-21)* — emoji vocabulary the convention
  prepends. Use this site to look up the ``:code:`` form (the
  convention requires the code form, not the literal emoji
  glyph) and which emoji matches which intent.
  carloscuesta/gitmoji repo + JSON are downstream of this site;
  the site is the canonical reference.

### Debugging methodology
*Language-neutral. How to investigate bugs — minimal reproduction,
scientific debugging, bisection.*

- [Minimal reproducible example — Stack Overflow](https://stackoverflow.com/help/minimal-reproducible-example)
  *(reviewed 2026-05-22)* — the canonical MRE guide. Three rules:
  **minimal** (least code that still triggers it), **complete**
  (anyone can copy-paste-run), **reproducible** (you ran it
  yourself and it failed). The single highest-leverage thing
  you can do when stuck on a bug. facet's one-off `panel-sandbox`
  executable target was an applied example: when the panel resize
  fix spiral hit 6 hours, isolating the AppKit knobs in a pure-
  AppKit sandbox app (no FacetCore / View / etc. dependencies)
  found the working `.resizable` config in 30 minutes. The
  pattern: **throwaway branch + `Sources/<Sandbox>` + new
  `.executableTarget` in Package.swift** ([[gui-bug-sandbox-ab-test]]).
- [Minimal reproducible example — Wikipedia](https://en.wikipedia.org/wiki/Minimal_reproducible_example)
  *(reviewed 2026-05-22)* — cross-language overview; same idea
  travels under MWE / MCVE / SSCCE / reprex. Useful when reading
  bug reports / issues in other ecosystems.
- [Scientific Debugging — Talin (Medium)](https://medium.com/machine-words/scientific-debugging-part-1-8890b73b6c4c)
  *(reviewed 2026-05-22)* — observe → hypothesise → experiment →
  repeat. The discipline that keeps a debugging session from
  becoming "try things until it works." facet's panel-resize
  post-mortem ([[panel-resize-postmortem]]) shows the cost of
  skipping the hypothesise step: 5+ fixes were tried before the
  underlying hypothesis ("AppKit `.resizable` works fine, our
  SidebarView autoresizing was the failure mode") got named.
- [Bisection (software engineering) — Grokipedia](https://grokipedia.com/page/Bisection_(software_engineering))
  *(reviewed 2026-05-22)* — when a bug was introduced by a change
  somewhere in history, `git bisect` finds it in O(log n) commits.
  facet's commit history is gitmoji + Conventional so each commit
  is a meaningful step — bisecting against it is cheap. Reach
  here when a regression appears that worked "yesterday" or in
  a pre-M2 build.

### CLI design
*Language-neutral UX principles for command-line tools.*

- [POSIX Utility Conventions (IEEE 1003.1, XBD §12)](https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap12.html)
  *(reviewed 2026-05-21)* — the source-of-truth specification
  every modern CLI inherits from. Argument syntax
  (`--long-option=VALUE`), exit-status semantics (0 = success,
  1+ = utility-specific failure, 2 = usage / syntax error),
  option ordering rules. facet's exit code split (0 / 2 / 3)
  maps directly here.
- [The Art of Unix Programming — Ch.1 *Basics of the Unix Philosophy*](http://www.catb.org/~esr/writings/taoup/html/ch01s06.html)
  *(reviewed 2026-05-21)* — the 17 rules. The ones facet
  actively follows: *Rule of Silence* (silent success on the
  happy path), *Rule of Repair* (loud + immediate failure,
  never silent fallback), *Rule of Composition* (stdout
  pipe-friendly), *Rule of Least Surprise* (canonical-only flag
  surface, no aliases). Old (2003) but the calibration still
  applies.
- [Command Line Interface Guidelines (clig.dev)](https://clig.dev/)
  *(reviewed 2026-05-21)* — modern (2020+) restatement of the
  above plus current conventions: stderr vs stdout, human- vs
  machine-readable output, idempotence. The post-M2 "no
  aliases, NAME required for every view op, typo wins over
  server-state check" decisions trace directly to clig.dev's
  *consistency* and *robustness* sections.
- [GNU Standards: Command-Line Interfaces](https://www.gnu.org/prep/standards/html_node/Command_002dLine-Interfaces.html)
  *(reviewed 2026-05-21)* — practical baseline for
  ``--long-options``, ``--help`` / ``--version`` conventions.

### Swift / Apple
*Language-specific: API correctness, concurrency, build.*

- [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)
  *(reviewed 2026-05-21)* — naming, doc-summary rules, protocol
  naming. Consulted when ``WindowBackend`` / ``Workspace`` /
  ``Window`` were designed (M2 step 1).
- [Swift 6 Migration Guide](https://www.swift.org/migration/documentation/migrationguide/)
  *(reviewed 2026-05-21)* — strict-concurrency migration
  patterns (``Sendable``, ``AsyncStream``, ``@MainActor``
  globals). Consulted when ``BackendEvent`` moved from callback
  to ``AsyncStream`` (M2 step 1 refactor).
- [Apple Developer — Swift Concurrency](https://developer.apple.com/documentation/swift/concurrency)
  *(reviewed 2026-05-21)* — authoritative reference for
  ``async`` / ``await`` / ``Task`` / actor / ``Sendable``. Use
  when implementing a new concurrent seam (e.g. extending
  ``Controller.start``'s event loop, adding a new
  actor-isolated cache).
- [Swift Package Manager docs](https://www.swift.org/documentation/package-manager/)
  *(reviewed 2026-05-21)* — ``Package.swift`` manifest, target
  / product / test-target declarations, dependency rules. Use
  when adding a module or test target (every new
  ``Sources/Facet*`` directory needs a matching ``.target``
  entry; new ``Tests/Facet*Tests`` needs a ``.testTarget``).
- [Swift Evolution](https://github.com/apple/swift-evolution)
  *(reviewed 2026-05-21)* — language proposal history. Look up
  an SE-NNNN when the rationale behind a strict-concurrency /
  Sendable / actor / isolation rule isn't obvious from the
  migration guide alone.

### macOS / Apple platform
*Platform-specific: AppKit, capture, signing, private symbols.*

- [Apple Developer Documentation (root)](https://developer.apple.com/documentation/)
  *(reviewed 2026-05-21)* — entry point for AppKit, Foundation,
  ScreenCaptureKit, ApplicationServices (AX) docs. Use when
  looking up an API signature or implementing against a new
  framework.
- [macOS Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/macos)
  *(reviewed 2026-05-21)* — agent / menu-bar-extra app design
  conventions. The ``LSUIElement = true`` choice (facet runs
  without a Dock icon) and the never-steal-focus
  ``.nonactivatingPanel`` design trace here.
- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
  *(reviewed 2026-05-21)* — macOS 14+ window capture API used
  by ``WindowPreview`` (sidebar hover preview + grid
  thumbnails). The Screen Recording permission rationale and
  the ``SCStreamConfiguration`` / ``SCContentFilter`` usage in
  ``Sources/FacetView/WindowPreview.swift`` follow the docs
  here.
- [Hardened Runtime / Code Signing](https://developer.apple.com/documentation/security/hardened_runtime)
  *(reviewed 2026-05-21)* — why ``setup-signing-cert.sh``
  exists: TCC keys the Accessibility grant to the code-signing
  identity, so ad-hoc signing loses the grant on every rebuild;
  a persistent self-signed cert keeps the identity stable
  across rebuilds.
- [NUIKit/CGSInternal (community)](https://github.com/NUIKit/CGSInternal)
  *(reviewed 2026-05-21)* — community-maintained header dump
  for private CGS / AX symbols like ``_AXUIElementGetWindow``
  (used in ``AXFocus.swift`` via ``dlsym``). No official Apple
  equivalent for these symbols; this is the de-facto reference.

### GitHub / CI
*Tool-specific: workflows, gh, releases.*

- [GitHub Docs (root)](https://docs.github.com)
  *(reviewed 2026-05-21)* — entry point for everything
  GitHub-related: Actions, REST API, releases, packages, gh
  CLI.
- [GitHub Actions documentation](https://docs.github.com/en/actions)
  *(reviewed 2026-05-21)* — workflow YAML syntax, events,
  contexts, expressions. Used to write the four workflows under
  ``.github/workflows/`` (build / commit-lint / release /
  update-tap). Look up ``on:`` events, ``concurrency:``
  semantics, secret access rules here.
- [GitHub REST API](https://docs.github.com/en/rest)
  *(reviewed 2026-05-21)* — used indirectly via ``gh api`` in
  ``update-tap.yml`` (e.g. release tag resolution). Reach here
  when the ``gh`` CLI lacks a high-level wrapper for the
  operation you need.
- [GitHub CLI manual (`gh`)](https://cli.github.com/manual/)
  *(reviewed 2026-05-21)* — ``gh release create`` / ``gh
  release edit`` / ``gh release upload`` are the bones of
  ``release.yml``'s rolling-draft flow; ``gh api`` shows up in
  ``update-tap.yml``.
- [Releasing projects on GitHub](https://docs.github.com/en/repositories/releasing-projects-on-github)
  *(reviewed 2026-05-21)* — draft-vs-published,
  tag-at-publish-time semantics that facet's rolling-draft
  release model relies on (no tag created until the maintainer
  Publishes manually).

### Development environment (Claude Code)
*Agent / IDE-specific: the tool driving the development loop.*

- [Claude Code docs (ja)](https://code.claude.com/docs/ja/overview)
  *(reviewed 2026-05-21)* — entry point for the agent /
  toolchain facet is being built with. Sub-pages of immediate
  interest:
  ``/docs/ja/memory`` (CLAUDE.md + auto-memory semantics,
  governs how rules in this file are loaded),
  ``/docs/ja/skills`` (custom skills like ``grill-me``,
  installed under ``~/.claude/skills/``),
  ``/docs/ja/settings`` (per-project / per-user
  ``settings.json``),
  ``/docs/ja/hooks`` (workflow automation triggers — facet's
  ``scripts/hooks/commit-msg`` is the local-git form, not the
  Claude Code form).

### Packaging / Release
*Distribution-specific: how the bundle reaches users.*

- [Homebrew](https://brew.sh/ja/)
  *(reviewed 2026-05-21)* — the distribution channel for the
  M3+ release. ``brew install akira-toriyama/tap/facet`` lands
  at M3; ``.github/workflows/update-tap.yml`` automates formula
  bumps on every published release. Consult when authoring or
  modifying the formula at ``akira-toriyama/homebrew-tap``.

### Sandbox / VM testing
*Clean-environment verification for host-affecting changes.*

- [Tart](https://github.com/cirruslabs/tart)
  *(reviewed 2026-05-27)* — Apple Virtualization.Framework-based
  macOS VM tool. facet uses it for clean-environment
  verification (v1→v2 upgrade smoke, fresh AX-permission grant
  flow, destructive `facet workspace --layout=bsp` sweeps that would
  scramble the host's real windows, private-API spike
  isolation). Subcommands relied on: ``clone`` (APFS COW —
  fast, only differences claim space), ``run`` (with
  ``--no-graphics`` for headless + ``tart ip`` for SSH, or
  ``--vnc`` for GUI capture), ``suspend`` (pauses execution
  preserving state — combined with ``clone`` gives
  snapshot-equivalent operation), ``exec`` (run a command in
  the VM without going through SSH), ``set`` (post-creation
  config including display resolution; default is
  ``1024x768``), ``delete`` / ``prune`` (cleanup).
  Trust boundary + standard workflow: ``tart-vm-testing-workflow``
  memory; specific verification cycles:
  ``tart-vm-verification-results-2026-05-27``.
- [tart.run](https://tart.run/quick-start/)
  *(reviewed 2026-05-27)* — official quick-start. Base image
  catalog is ``ghcr.io/cirruslabs/macos-<release>-base``
  (e.g. ``macos-sequoia-base``); SSH defaults to
  ``admin``/``admin`` with NOPASSWD sudo. The quick-start
  mostly documents the happy path — for sharper operational
  detail (esp. snapshot / suspend / exec / clone semantics),
  reach for ``tart help <subcommand>`` directly.

