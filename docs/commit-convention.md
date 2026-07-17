# Commit convention

The commit-message convention (gitmoji-driven — the leading gitmoji is the
type and drives release semver; scopes, examples, breaking-change rules) is shared
across every repository under this account and lives in a single source of
truth:

**https://github.com/akira-toriyama/.github/blob/main/CONTRIBUTING.md**

This file is only a pointer, so the convention lives in exactly one place. It is
distributed fleet-wide from a canonical copy in
[`akira-toriyama/.github`](https://github.com/akira-toriyama/.github/blob/main/fleet/commit-convention.md);
edit that copy, not this one — the fleet-sync workflow overwrites this file on
its next run.

The format is enforced in CI by the shared `commit-lint.yml` workflow, which is
distributed to every repo the same way, so a non-conforming message fails the
check on each pull request.
