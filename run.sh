#!/bin/zsh
# Build + run the LOCAL dev .app bundle.
# (Release packaging is `./package.sh` — used by Homebrew.)
# Quit any running instance:  pkill -f /Contents/MacOS/facet
set -e
cd "$(dirname "$0")"
./package.sh --dev
# Stop any prior instance — match the executable name so both flavors
# (Facet-dev.app + Homebrew's Facet.app) are caught, plus any raw
# SwiftPM binary left running during early development.
pkill -f '/Contents/MacOS/facet'   2>/dev/null || true
pkill -f '\.build/.*/facet'        2>/dev/null || true
sleep 1
open ./Facet-dev.app
echo "facet (dev) launched. Grant Accessibility + Screen Recording on first run."
