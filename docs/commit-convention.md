# Commit convention

What a commit message means in this repository is decided by **this
repository's own `glyph.toml`** — the committed pattern file that
[glyph](https://github.com/akira-toriyama/glyph) reads in CI (`commit-lint`),
at release time, and in the local hooks. The sigil in the subject (`=` `~`
`^` `!` `%`) is the version signal; glyph's README ("Commit format") is the
reference for the vocabulary.

The account-wide conventions that sit above any pattern file (language,
PR-title rule, removals, migration state) live in one place:

**https://github.com/akira-toriyama/.github/blob/main/CONTRIBUTING.md**

This file is only a pointer. It is distributed fleet-wide from a canonical
copy in
[`akira-toriyama/.github`](https://github.com/akira-toriyama/.github/blob/main/fleet/commit-convention.md);
edit that copy, not this one — the fleet-sync workflow overwrites this file
on its next run.
