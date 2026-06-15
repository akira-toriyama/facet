#!/bin/zsh
# Kill every running facet instance — release bundle, dev bundle,
# or raw SwiftPM binary. Use when you've lost track of which one
# is up (verification sessions often pile up). Safe to run when
# nothing is running (no-op + "(none running)").
#
#   ./stop.sh
#
# Matching is by EXECUTABLE PATH (ps comm), never by command-line
# string. A shell whose command line merely *mentions* a facet
# path — `./run.sh && .build/release/facet query` — must neither
# be killed nor counted as a survivor (issue #214: the old
# `ps aux | grep` confirmation false-matched the calling shell,
# so run.sh's `set -e` aborted between the kill and the relaunch,
# leaving no server at all).

set -e
cd "$(dirname "$0")"

# PIDs whose executable is a facet binary (bundle or SwiftPM build).
# `read` keeps everything after the PID in $comm, so executable
# paths containing spaces survive.
facet_pids() {
    ps -axo pid=,comm= | while read -r pid comm; do
        case "$comm" in
            */Contents/MacOS/facet|*.build/*/facet) print -r -- "$pid" ;;
        esac
    done
}

pids="$(facet_pids)"
if [[ -z "$pids" ]]; then
    echo "killed: all facet instances (none running)"
    exit 0
fi
echo "$pids" | xargs kill 2>/dev/null || true

# Confirmation pass: anything still alive? Give TERM a moment
# (bounded ~2s; exits the loop as soon as the table is clear).
remaining="$(facet_pids)"
for _ in {1..10}; do
    [[ -z "$remaining" ]] && break
    sleep 0.2
    remaining="$(facet_pids)"
done
if [[ -n "$remaining" ]]; then
    echo "warning: some facet instances survived:" >&2
    for pid in ${(f)remaining}; do
        ps -p "$pid" -o pid=,comm= >&2 || true
    done
    exit 1
fi
echo "killed: all facet instances"
