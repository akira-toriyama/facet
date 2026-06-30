# Commit convention

The commit-message convention (gitmoji + Conventional Commits — the types that
drive release semver, scopes, examples, and breaking-change rules) is shared
across every repository under this account and lives in a single source of
truth:

**https://github.com/akira-toriyama/.github/blob/main/CONTRIBUTING.md**

This file used to carry a per-repo copy; it has been reduced to a pointer so the
convention lives in exactly one place.

## Local hook

```sh
git config core.hooksPath scripts/hooks
```

`scripts/hooks/commit-msg` validates the message format before each commit —
the same rules CI's `commit-lint.yml` enforces.
