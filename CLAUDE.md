# CLAUDE.md

Guidance for working in this repository.

## What this is

`facet` — Swift workspace + window manager for macOS. **Architectural
successor to [ws-tabs](https://github.com/akira-toriyama/ws-tabs)**: 1
binary, multiple views (`--view=tree|grid|…`), 1 backend at a time
(`rift-cli` adapter today, native AX/CGS adapter in M5+). Swift 6,
macOS 13+. See [docs/architecture.md](docs/architecture.md) for the
layer diagram.

## Build / run

```sh
swift build                # compile (works on CommandLineTools)
swift test                 # tests — needs Xcode (XCTest); fails on CLT
.build/debug/facet         # bootstrap stub output until M2 wires views
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

## Non-obvious constraints — read before editing

### Layer rules (the spine of the project)

- **3 layers are non-negotiable**: `FacetCore` is pure logic
  (CoreGraphics OK, NO AppKit / NO backend / NO OS interaction).
  `FacetAdapter*` wraps a backend (rift-cli, AX, …) and is the
  *only* place those types appear. `FacetView*` is GUI-only.
  Crossing layers always means there's a missing protocol.
- **`RF*` types stay inside `FacetAdapterRift`**.
  [Sources/FacetAdapterRift/RFTypes.swift](Sources/FacetAdapterRift/RFTypes.swift)
  is internal-by-design.
  [Sources/FacetAdapterRift/Mapper.swift](Sources/FacetAdapterRift/Mapper.swift)
  converts to the backend-neutral
  [Sources/FacetCore/Models.swift](Sources/FacetCore/Models.swift)
  types at the seam. Views and controller must never see `RFWorkspace`.
- **Views talk to the `WindowBackend` protocol, never to
  `RiftAdapter` directly**. This is what lets M5+ swap in
  `FacetAdapterNative` without touching a single view file.

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
- **Window titles are AX-resolved when rift returns blank**. rift's
  `query workspaces` returns empty `title` for many apps (Chrome,
  Code, …). `AXTitles.resolve` reads `kAXTitle` directly, short-TTL
  cached, only off-main. Don't assume `Window.title` is populated by
  the backend alone. (Memory:
  [[window-titles-AX-resolved]].)
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

- **`/opt/homebrew/bin/rift-cli` is hard-coded** in
  [Sources/FacetAdapterRift/RiftCLI.swift](Sources/FacetAdapterRift/RiftCLI.swift).
  Don't add configurability — M5+ replaces this entire module with
  `FacetAdapterNative` (Phases α–ε). Engineering effort on this
  module has a sunset date.
- **AX helpers (focus + title resolution) live in
  `FacetAdapterRift` for now**. They aren't actually rift-specific
  (any backend benefits from AX) — they'll move to a shared
  `FacetAccessibility` module when the native adapter arrives
  (M5+). Place new AX code there, marked with a `// MOVE-AT-M5`
  comment if it would belong in the shared module.
- **Bundle id will be `com.facet.app`** once
  [package.sh](packaging/) lands in M2 step 8. NOT `com.wstabs.app`
  — separate TCC grants, separate self-signed cert. Don't reuse
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
  always key/active by construction.
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
- **Migration is code copy + restructure**, NOT git history merge.
  ws-tabs gets archived (M4) — don't pull commits from it.

## Conventions

- **Commit messages**: gitmoji + Conventional Commits —
  `<:gitmoji:> <type>(<scope>)<!>: <subject>`. Full spec:
  [docs/commit-convention.md](docs/commit-convention.md). Enable
  the local hook: `git config core.hooksPath scripts/hooks` (script
  lands in M2 step 8).
- **README is bilingual** ([README.md](README.md) English +
  [README.ja.md](README.ja.md) Japanese). Keep them in sync when
  user-visible behavior changes. Memory [[readme-bilingual]].
- After source edits, **`swift build` must pass** before finishing
  a turn.

## References

External material that informed facet's API / architecture
decisions. Kept here so the rationale survives future
contributors (human or AI) reopening the repo cold.

### Swift / Apple
- [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)
  — naming, doc-summary rules, protocol naming. Consulted when
  ``WindowBackend`` / ``Workspace`` / ``Window`` were designed
  (M2 step 1).
- [Swift 6 Migration Guide](https://www.swift.org/migration/documentation/migrationguide/)
  — strict-concurrency migration patterns (``Sendable``,
  ``AsyncStream``, ``@MainActor`` globals). Consulted when
  ``BackendEvent`` moved from callback to ``AsyncStream`` (M2
  step 1 refactor).
- [Apple Developer — Swift Concurrency](https://developer.apple.com/documentation/swift/concurrency)
  — authoritative reference for ``async`` / ``await`` /
  ``Task`` / actor / ``Sendable``. Use when implementing a new
  concurrent seam (e.g. extending ``Controller.start``'s event
  loop, adding a new actor-isolated cache).
- [Swift Package Manager docs](https://www.swift.org/documentation/package-manager/)
  — ``Package.swift`` manifest, target / product / test-target
  declarations, dependency rules. Use when adding a module or
  test target (every new ``Sources/Facet*`` directory needs a
  matching ``.target`` entry; new ``Tests/Facet*Tests`` needs a
  ``.testTarget``).
- [Swift Evolution](https://github.com/apple/swift-evolution)
  — language proposal history. Look up an SE-NNNN when the
  rationale behind a strict-concurrency / Sendable / actor /
  isolation rule isn't obvious from the migration guide alone.

### macOS / Apple platform
- [Apple Developer Documentation (root)](https://developer.apple.com/documentation/)
  — entry point for AppKit, Foundation, ScreenCaptureKit,
  ApplicationServices (AX) docs. Use when looking up an API
  signature or implementing against a new framework.
- [macOS Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/macos)
  — agent / menu-bar-extra app design conventions. The
  ``LSUIElement = true`` choice (facet runs without a Dock icon)
  and the never-steal-focus ``.nonactivatingPanel`` design
  trace here.
- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
  — macOS 14+ window capture API used by ``WindowPreview``
  (sidebar hover preview + grid thumbnails). The Screen Recording
  permission rationale and the ``SCStreamConfiguration`` /
  ``SCContentFilter`` usage in ``Sources/FacetView/WindowPreview.swift``
  follow the docs here.
- [Hardened Runtime / Code Signing](https://developer.apple.com/documentation/security/hardened_runtime)
  — why ``setup-signing-cert.sh`` exists: TCC keys the
  Accessibility grant to the code-signing identity, so ad-hoc
  signing loses the grant on every rebuild; a persistent
  self-signed cert keeps the identity stable across rebuilds.
- [NUIKit/CGSInternal (community)](https://github.com/NUIKit/CGSInternal)
  — community-maintained header dump for private CGS / AX
  symbols like ``_AXUIElementGetWindow`` (used in
  ``AXFocus.swift`` via ``dlsym``). No official Apple equivalent
  for these symbols; this is the de-facto reference.

### CLI design
- [POSIX Utility Conventions (IEEE 1003.1, XBD §12)](https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap12.html)
  — the source-of-truth specification every modern CLI inherits
  from. Argument syntax (`--long-option=VALUE`), exit-status
  semantics (0 = success, 1+ = utility-specific failure, 2 =
  usage / syntax error), option ordering rules. facet's exit
  code split (0 / 2 / 3) maps directly here.
- [The Art of Unix Programming — Ch.1 *Basics of the Unix Philosophy*](http://www.catb.org/~esr/writings/taoup/html/ch01s06.html)
  — the 17 rules. The ones facet actively follows: *Rule of
  Silence* (silent success on the happy path), *Rule of Repair*
  (loud + immediate failure, never silent fallback), *Rule of
  Composition* (stdout pipe-friendly), *Rule of Least Surprise*
  (canonical-only flag surface, no aliases). Old (2003) but the
  calibration still applies.
- [Command Line Interface Guidelines (clig.dev)](https://clig.dev/)
  — modern (2020+) restatement of the above plus current
  conventions: stderr vs stdout, human- vs machine-readable
  output, idempotence. The post-M2 "no aliases, NAME required
  for every view op, typo wins over server-state check"
  decisions trace directly to clig.dev's *consistency* and
  *robustness* sections.
- [GNU Standards: Command-Line Interfaces](https://www.gnu.org/prep/standards/html_node/Command_002dLine-Interfaces.html)
  — practical baseline for ``--long-options``, ``--help`` /
  ``--version`` conventions.

### Architecture (Hexagonal / Clean Architecture / DDD)
- [Hexagonal Architecture / Ports & Adapters (Alistair Cockburn)](https://alistair.cockburn.us/hexagonal-architecture/)
  — the pattern facet's 3-layer split is literally implementing.
  ``WindowBackend`` protocol = a Port; ``RiftAdapter`` = an
  Adapter; ``FacetCore`` lives inside the hexagon. Clean
  Architecture restates this idea with more layers; the
  rosetta-stone table in
  [docs/architecture.md](docs/architecture.md) shows the mapping.
- [jasontaylordev/cleanarchitecture](https://github.com/jasontaylordev/cleanarchitecture)
  — canonical CA 4-layer template (.NET reference for the
  concept).
- [sergdort/ModernCleanArchitectureSwiftUI](https://github.com/sergdort/ModernCleanArchitectureSwiftUI)
  — Swift-native CA module layout. The Domain / Platform /
  Features / Application split informed the rosetta-stone table
  in [docs/architecture.md](docs/architecture.md).
- [tuan188/CleanArchitecture](https://github.com/tuan188/CleanArchitecture)
  — second Swift-CA reference; consult if a fundamental
  restructure is on the table.
- [GitHub topic: domain-driven-design](https://github.com/topics/domain-driven-design)
  — entry point for cross-language DDD pattern examples.

### GitHub / CI
- [GitHub Docs (root)](https://docs.github.com)
  — entry point for everything GitHub-related: Actions, REST
  API, releases, packages, gh CLI.
- [GitHub Actions documentation](https://docs.github.com/en/actions)
  — workflow YAML syntax, events, contexts, expressions. Used
  to write the four workflows under ``.github/workflows/``
  (build / commit-lint / release / update-tap). Look up
  ``on:`` events, ``concurrency:`` semantics, secret access
  rules here.
- [GitHub REST API](https://docs.github.com/en/rest)
  — used indirectly via ``gh api`` in ``update-tap.yml`` (e.g.
  release tag resolution). Reach here when the ``gh`` CLI lacks
  a high-level wrapper for the operation you need.
- [GitHub CLI manual (`gh`)](https://cli.github.com/manual/)
  — ``gh release create`` / ``gh release edit`` / ``gh release
  upload`` are the bones of ``release.yml``'s rolling-draft
  flow; ``gh api`` shows up in ``update-tap.yml``.
- [Releasing projects on GitHub](https://docs.github.com/en/repositories/releasing-projects-on-github)
  — draft-vs-published, tag-at-publish-time semantics that
  facet's rolling-draft release model relies on (no tag
  created until the maintainer Publishes manually).

