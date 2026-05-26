#!/usr/bin/env bash
# remove_workspace.sh — remove a workspace entry from
# ~/.config/facet/config.toml's `[workspace]` section.
#
# Usage:
#   remove_workspace.sh <N>
#
# Idempotent: re-running when the entry is already absent is a
# no-op (exit 0).
#
# Atomic write — same contract as add_workspace.sh (memory
# [[facet-cli-surface]] N15).
#
# Env:
#   FACET_CONFIG  override config path (default ~/.config/facet/config.toml)

set -euo pipefail

CONFIG="${FACET_CONFIG:-$HOME/.config/facet/config.toml}"
N="${1:-}"

if [[ -z "$N" || ! "$N" =~ ^[0-9]+$ ]]; then
    echo "usage: $(basename "$0") <N>" >&2
    exit 2
fi

if [[ ! -f "$CONFIG" ]]; then
    echo "error: $CONFIG not found" >&2
    exit 3
fi

TMP=$(mktemp "${CONFIG}.XXXXXX")
trap 'rm -f "$TMP"' EXIT

python3 - "$CONFIG" "$N" > "$TMP" <<'PY'
import sys
path, n = sys.argv[1], sys.argv[2]
with open(path) as f:
    lines = f.read().splitlines()

ws_start = None
ws_end = len(lines)
for i, line in enumerate(lines):
    if line.strip() == "[workspace]":
        ws_start = i
    elif ws_start is not None and line.lstrip().startswith("["):
        ws_end = i
        break

target_prefix = f"{n} ="
if ws_start is not None:
    section = [
        line for line in lines[ws_start:ws_end]
        if not line.lstrip().startswith(target_prefix)
    ]
    lines = lines[:ws_start] + section + lines[ws_end:]

sys.stdout.write("\n".join(lines) + "\n")
PY

mv "$TMP" "$CONFIG"
trap - EXIT
# Idempotent: re-running when the entry's already gone is a no-op,
# so the user-facing message just says "removed" either way.
echo "$CONFIG: workspace $N removed"
