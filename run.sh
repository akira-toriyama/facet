#!/bin/zsh
# Build + launch a facet .app bundle locally. Defaults to release
# (Facet.app, com.facet.app) — the bundle you'd actually use day
# to day. ``--dev`` builds the parallel Facet-dev.app
# (com.facet.app.dev) for verification alongside a Homebrew
# install without TCC grant collisions.
#
#   ./run.sh             release → Facet.app
#   ./run.sh --dev       dev     → Facet-dev.app
#
# Always kills any currently-running facet first (via stop.sh) so
# the new bundle takes over cleanly. Quit later: ``./stop.sh`` or
# ``facet --quit``.
set -e
cd "$(dirname "$0")"

MODE=""
APP="Facet.app"
if [[ "${1:-}" == "--dev" ]]; then
    MODE="--dev"
    APP="Facet-dev.app"
fi

./package.sh $MODE
./stop.sh
sleep 0.5
open "./$APP"
echo "$APP launched. Grant Accessibility + Screen Recording on first run."
