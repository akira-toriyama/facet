# Commit convention & versioning

This repo commits with **gitmoji + Conventional Commits**; from the messages
[git-cliff](https://git-cliff.org) computes semver and the release notes.

## Format

```
<gitmoji> <type>(<scope>)<!>: <subject>

<body, optional>

<footer, optional / BREAKING CHANGE: ...>
```

- `<gitmoji>` … exactly one leading gitmoji in the `:sparkles:` **text form**
  (grep-friendly; not the emoji glyph). e.g. `:bug:`.
- `<type>` … Conventional Commits type (`feat` `fix` `perf` `refactor` `docs`
  `test` `build` `ci` `chore` `style` `revert`). **semver is decided by this.**
- `<scope>` … optional, **parenthesised only**: `(ui)` `(cli)` `(native)`
  `(packaging)` `(homebrew)` `(ci)` `(dist)` `(grid)` etc. For sub-scopes
  use dashes inside the parens (`(grid-1f-4)`, not `(grid)[1f-4]` — the
  bracketed form fails the CI lint pattern). Multi-word scopes go inside
  the parens too: `(commit-lint)`, `(update-tap)`.
- `!` … breaking change. Or a `BREAKING CHANGE: <desc>` footer.
- `<subject>` … imperative, concise. English or Japanese (match history).

### Examples

```
:sparkles: feat(ui): right-click window menu (float / fullscreen / close)
:bug: fix(native): re-assert AX focus after a display reconfigure
:zap: perf(cli): dispatch the DNC broadcast off the main thread
:boom: feat!: rename product to facet (bundle id com.wstabs.app)
:memo: docs: document the Homebrew tap flow
:wrench: chore: strengthen .gitignore
:green_heart: ci: pin latest-stable Xcode (Swift 6)
```

## semver mapping

| Change | Type / marker | Version |
|---|---|---|
| Breaking change | `<type>!` / `BREAKING CHANGE:` | **major** |
| New feature | `feat` | **minor** |
| Bug fix / perf | `fix` / `perf` | **patch** |
| Everything else (`docs` `ci` `chore` `style` `test` `refactor` `build`) | — | **no bump** |

The **type is authoritative** for semver; gitmoji is for readability and
changelog grouping (if they disagree, the type wins). Bot commits
(`github-actions`, `*[bot]`) are excluded from versioning and the changelog
(see [cliff.toml](../cliff.toml) `commit_parsers`).

## Release flow

Releases are automated by [.github/workflows/release.yml](../.github/workflows/release.yml)
(rolling-draft model):

1. Merge `feat:`/`fix:`/`perf:` to `main`. git-cliff computes the next version
   and the workflow creates/updates a single **draft** GitHub Release with the
   built `Facet.zip` attached. No tag yet.
2. Review the draft; **Publish** it in the GitHub UI — GitHub creates the tag
   (`vX.Y.Z`) on the target commit at publish time.
3. Point Homebrew at the new tag (see
   [packaging/homebrew/README.md](../packaging/homebrew/README.md)).

`workflow_dispatch` with `dry_run=true` is a full preview (no draft, no
version consumed). Non-bumping-only changes ⇒ the workflow no-ops.

The initial version is `v1.0.0` ([cliff.toml](../cliff.toml) `initial_tag`).
CHANGELOG is not pushed to `main`; the GitHub Release notes are canonical.

## Local hook (optional, low-dependency)

No Node required. Enable the bundled shell hook:

```sh
git config core.hooksPath scripts/hooks
```

`commit-msg` validates the gitmoji + Conventional form. CI validates the same
on every PR via [.github/workflows/commit-lint.yml](../.github/workflows/commit-lint.yml).
