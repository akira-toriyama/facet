#!/bin/zsh
# Build + launch a facet .app bundle locally. Defaults to release
# (Facet.app, com.facet.app) — the bundle you'd actually use day
# to day. ``--dev`` builds the parallel Facet-dev.app
# (com.facet.app.dev) for verification alongside a Homebrew
# install without TCC grant collisions.
#
#   ./run.sh                            release → Facet.app (FACET_DEBUG on)
#   ./run.sh --dev                      dev     → Facet-dev.app (FACET_DEBUG on)
#   FACET_BACKEND=native ./run.sh       opt into the native adapter
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

# Forward facet-specific env vars into the bundle. `open` doesn't
# inherit the calling shell's environment (macOS Launch Services
# starts the .app in its own context), so anything set on the
# command line — most importantly FACET_BACKEND for the in-progress
# native adapter — has to be passed through explicitly via
# `open --env KEY=VALUE`.
OPEN_ARGS=()
for VAR in FACET_BACKEND; do
    if [[ -n "${(P)VAR:-}" ]]; then
        OPEN_ARGS+=(--env "$VAR=${(P)VAR}")
    fi
done
# run.sh is the local dev/debug launcher → always set FACET_DEBUG so
# /tmp/facet.log gets the verbose lines (incl. `gate=` / `exclude=`
# window-classification decisions). There is no `--debug` CLI flag:
# debug is env-var-triggered, so a brew / raw `open Facet.app` stays
# quiet. `open` doesn't inherit the shell env, so it goes via --env.
open "./$APP" --env FACET_DEBUG=1 "${OPEN_ARGS[@]}"
echo "$APP launched. Grant Accessibility + Screen Recording on first run."
[[ ${#OPEN_ARGS[@]} -gt 0 ]] && echo "forwarded env: ${OPEN_ARGS[*]}"
