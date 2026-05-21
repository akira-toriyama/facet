#!/bin/zsh
# Kill every running facet instance — release bundle, dev bundle,
# or raw SwiftPM binary. Use when you've lost track of which one
# is up (verification sessions often pile up). Safe to run when
# nothing is running (no-op + "(none running)").
#
#   ./stop.sh
#
# rift itself is left alone (it's the WM, not a facet instance).

set -e
cd "$(dirname "$0")"

pkill -f '/Contents/MacOS/facet' 2>/dev/null || true
pkill -f '\.build/.*/facet'      2>/dev/null || true

# Confirmation pass: anything still alive?
remaining="$(ps aux \
    | grep -E '/Contents/MacOS/facet|\.build/.*/facet' \
    | grep -v grep || true)"
if [[ -n "$remaining" ]]; then
    echo "warning: some facet instances survived:" >&2
    echo "$remaining" >&2
    exit 1
fi
echo "killed: all facet instances"
