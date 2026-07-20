# References

External material that informed facet's API / architecture
decisions. Kept here (moved out of CLAUDE.md to keep that file
lean) so the rationale survives future contributors (human or AI)
reopening the repo cold.

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
  account-wide
  [CONTRIBUTING.md](https://github.com/akira-toriyama/.github/blob/main/CONTRIBUTING.md)
  is built on. Releases are driven by
  [glyph](https://github.com/akira-toriyama/glyph): the leading
  ``:code:`` gitmoji is the change type, and the next semver is
  derived from each merged PR's individual (pre-squash) commits
  (`glyph rules` prints the embedded table; the git-cliff era
  ``cliff.toml`` is gone).
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
  by ``SCKWindowCapture`` (sidebar hover preview + grid
  thumbnails), the sole ScreenCaptureKit consumer, behind
  FacetCore's ``WindowCapturing`` port (P7). The Screen Recording
  permission rationale and the ``SCStreamConfiguration`` /
  ``SCContentFilter`` usage in
  ``Sources/FacetCapture/SCKWindowCapture.swift`` follow the docs
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
  ``/docs/ja/hooks`` (workflow automation triggers — distinct from the
  local-git ``commit-msg`` hook that ``glyph hook install`` writes).

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
  flow, destructive `facet workspace --layout bsp` sweeps that would
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
