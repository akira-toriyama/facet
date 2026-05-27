# CLAUDE.md

Guidance for working in this repository.

## What this is

`facet` — Swift workspace + window manager for macOS. **Architectural
successor to [ws-tabs](https://github.com/akira-toriyama/ws-tabs)**:
multiple views (`--view=tree|grid|…`), native AX/CGS backend
(`FacetAdapterNative`, sole backend since v2.0.0). Swift 6,
macOS 13+.

**1 repo / 2 product** (decided 2026-05-24): `facet` (surface-core,
SIP-on, M5 now) and `facet-x` (deep-core, SIP-off opt-in, M6+).
Same Swift package, separate binaries, brew dependency
`facet-x ⊃ facet`. See [docs/architecture.md](docs/architecture.md)
"Two-binary structure" + Phase α frozen decisions.

## Build / run

```sh
swift build                # compile (works on CommandLineTools)
swift test                 # tests — needs Xcode (XCTest); fails on CLT
.build/debug/facet         # raw client (use ./run.sh for the .app bundle)
```

`swift test` does NOT work on CommandLineTools-only setups (`no such
module 'XCTest'`). Same constraint as ws-tabs — tests run in CI
([build workflow lands in M2 step 7](docs/architecture.md)). Locally,
`swift build` is the bar; let CI cover XCTest.

`@main enum FacetApp` lives in
[Sources/FacetApp/Main.swift](Sources/FacetApp/Main.swift) (NOT
top-level code in a `main.swift`) so XCTest's executable-target
`@testable import` keeps working once tests land. **Don't reintroduce
a `main.swift` file** — same trap as ws-tabs.

### Debugging facet (the agent run loop)

facet is a live GUI agent, so verifying a change means running the
real app and watching it. The loop an AI agent (Claude Code) should
use:

```sh
./run.sh          # build release → kill any running facet → launch Facet.app
./stop.sh         # kill all facet instances (release / dev / raw SwiftPM)
.build/release/facet --debug 2>&1 | tee /tmp/facet-bug-$(date +%H%M%S).log &
                  # foreground server with verbose log (timestamped so
                  # runs don't pile up); read the file directly to inspect
```

- **The agent may run `./stop.sh` / `./run.sh` / `swift build`
  freely while debugging** — it doesn't need to ask each time. The
  human pilots the panel (clicks / drags / keys) and reports; the
  agent drives build + relaunch. (This pairs with: the agent reads
  `/tmp/facet*.log` directly rather than asking for pasted output.)
- **GUI bugs: observe before theorising.** A screen recording can
  be frame-extracted (`ffmpeg -i in.mov -vf fps=3 f_%02d.png`) and
  the PNGs read directly; `--debug` logs every Controller / Adapter
  hot-path event. Cursor shape + panel position in a frame tell you
  whether a click hit its target — facts, not guesses.
- **When ≥2 fixes haven't worked, isolate in a sandbox.** A pure-
  AppKit `.executableTarget` (no FacetCore / View deps) that opens
  the offending construct in several variant configs A/B-tests the
  OS behaviour without facet's noise. The
  [`sandbox/panel-resize-tester`](https://github.com/akira-toriyama/facet/tree/sandbox/panel-resize-tester)
  branch is the worked example (it's how the chevron → `.resizable`
  switch was found). See References → *Debugging methodology*.

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

### Ported from ws-tabs — keep the contracts intact

- **`pal` is a `@MainActor` module-level var in
  [Sources/FacetView/Theme.swift](Sources/FacetView/Theme.swift)**.
  The symbol name is preserved deliberately — every lifted view file
  references `pal.text`, `pal.dim`, etc. in dozens of places. Don't
  rename it to `Theme.current` or similar; it would touch ~hundreds
  of view-side lines for zero behavior gain.
- **`Palette` presets (`.terminal` / `.cute` / `.system`) are
  `@MainActor`** because `NSColor` is not `Sendable` under Swift 6
  strict concurrency. Don't try to make them ordinary top-level
  `let`s.
- **Window titles are AX-resolved**. `AXTitles.resolve` reads
  `kAXTitle` directly, short-TTL cached, only off-main. Don't
  assume `Window.title` is populated by the backend alone.
  (Memory: [[window-titles-AX-resolved]].)
- **`FlippedClipView` is used from day one**. ws-tabs's 2026-05-21
  "intermittent grip drag failure" traced back to a non-flipped
  `NSClipView` (memory [[grid-branch-grip-intermittent]]). Adopt
  `FlippedClipView` for every scroll view, not "once we hit the
  same bug."
- **The drag-state lifecycle is a backend round-trip flag**, not a
  mouse-event flag. Don't clear it on `mouseUp` — clear it when the
  backend confirms the move. Memory:
  [[grid-drag-state-lifecycle]].

### M2 / M5 boundaries

- **Native adapter is the sole backend** (v2.0.0 retired rift).
  M5 surface-core complete: Phase α (workspaces + focus + AX
  events), β (anchor / minimize hide, closeWindow, setupFiles
  startup hook), γ (BSP + stack tiling, AX-role auto-float for
  sheets / dialogs / palettes, 5 CLI verbs: `--set-layout=NAME`,
  `--retile`, and three `facet window` flags `--toggle-float`,
  `--toggle-orientation`, `--cycle-stack=next|prev`), δ (display
  reconfigure), ε (rift retire) all shipped. See `facet --help`
  and [docs/architecture.md](docs/architecture.md) for the contracts.
- **AX helpers live in `FacetAccessibility`** (extracted at M5;
  sole consumer now is `FacetAdapterNative` after Phase ε
  retired rift). `AXFocus`, `AXTitles`, `Focus.assert` /
  `withRetry`, `AXGeom` (window lookup / position / size / close
  button), `Displays` (screen-containing-point), and
  `WindowEventObserver` (per-app AX subscription) all live here.
  New AX code goes here unless it's truly backend-specific.
- **Bundle id is `com.facet.app`** (M2 done). See
  [package.sh](package.sh) at repo root. NOT `com.wstabs.app` —
  separate TCC grants, separate self-signed cert. Don't reuse
  ws-tabs's id even temporarily.

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
- **No bare-flag tree aliases**. ``--show`` / ``--hide`` /
  ``--toggle`` / ``--active`` standalone were dropped — every
  view op specifies NAME explicitly. Keeps the canonical form
  unambiguous (no "is ``--hide`` short for ``--hide=tree`` or
  is it the legacy bare verb?" surface area). Shorthand is the
  user's shell-alias problem, not facet's. Reintroducing bare
  flags also means reintroducing per-view dispatch ambiguity
  when a new view (dock, palette, …) lands.
- **``--view=NAME`` is idempotent (show)**, not toggle. To
  toggle, use ``--toggle=NAME``. This is the one behaviour
  change vs ws-tabs; do not regress it back to toggle-on-show.
- **Typo rejection is loud**: unknown view / theme names
  ``exit 2`` with a stderr message. Silent fallback is the
  ws-tabs misfeature we deliberately don't reproduce.
- **State-changing scripts honour ``--dry-run`` and tee a log
  by default**. Any script that mutates the user's environment
  (screen recording, mouse events, network posts, file writes
  outside the repo) ships:
  - ``--dry-run`` — print what would happen instead of executing
    (clig.dev *robustness*: make state changes preview-able).
  - tee of stdout/stderr to ``/tmp/<script>.log`` *on by default*
    so reruns + agent inspection are easy; ``--silent`` opts
    out. The inverted polarity (log-on by default, not
    ``--debug``-gated like the app) reflects the different
    audience: scripts are run rarely + interactively, the app
    runs continuously.

  The application CLI itself (``facet --view=*`` etc.) is
  idempotent / DNC-broadcast and doesn't need ``--dry-run``;
  its logging is ``--debug``-gated for the opposite reason
  (long-lived server, default-quiet stderr). This rule applies
  to repo-local automation, not to the app surface.

### Logging

- **`Log` lives in `FacetCore`** so both adapters and view modules
  can call it without crossing layer rules. Two functions:
  ``Log.line`` (always on, for end-user-visible operational events
  like AX focus mismatches) and ``Log.debug`` (gated by the
  ``debugMode`` global, set from ``facet --debug`` at startup).
- **Both write to `/tmp/facet.log`**; ``--debug`` also mirrors to
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
  workflow inherited from ws-tabs (memory
  [[grid-view-work-style]]). Commit locally freely; pushing /
  merging waits for トミー's go.
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
- **Migration is code copy + restructure**, NOT git history merge.
  ws-tabs gets archived (M4) — don't pull commits from it.

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
  you can do when stuck on a bug. facet's
  [`sandbox/panel-resize-tester`][sandbox-branch] branch + the
  `panel-sandbox` executable target are an applied example: when
  the panel resize fix spiral hit 6 hours, isolating the AppKit
  knobs in a pure-AppKit sandbox app (no FacetCore / View / etc.
  dependencies) found the working `.resizable` config in 30
  minutes. The pattern: **branch + `Sources/<Sandbox>` + new
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

[sandbox-branch]: https://github.com/akira-toriyama/facet/tree/sandbox/panel-resize-tester

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

