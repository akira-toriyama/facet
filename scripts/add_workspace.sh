#!/usr/bin/env bash
# add_workspace.sh — add or update a workspace entry in
# ~/.config/facet/config.toml's `[workspace]` section.
#
# Usage:
#   add_workspace.sh <N> [name]
#
# Examples:
#   add_workspace.sh 1 dev
#   add_workspace.sh 5                  # creates an empty-name slot
#
# Idempotent: re-running with the same N rewrites the row.
#
# Atomic write — uses `mktemp` + `mv` so facet's ConfigWatcher
# never sees a half-written file. Honors the contract in memory
# [[facet-cli-surface]] N15.
#
# Env:
#   FACET_CONFIG  override config path (default ~/.config/facet/config.toml)

set -euo pipefail

CONFIG="${FACET_CONFIG:-$HOME/.config/facet/config.toml}"
N="${1:-}"
NAME="${2:-}"

if [[ -z "$N" || ! "$N" =~ ^[0-9]+$ ]]; then
    echo "usage: $(basename "$0") <N> [name]" >&2
    exit 2
fi

if [[ ! -f "$CONFIG" ]]; then
    echo "error: $CONFIG not found" >&2
    echo "       run the install command from the README first." >&2
    exit 3
fi

TMP=$(mktemp "${CONFIG}.XXXXXX")
trap 'rm -f "$TMP"' EXIT

python3 - "$CONFIG" "$N" "$NAME" > "$TMP" <<'PY'
import sys
path, n, name = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    lines = f.read().splitlines()

# Locate the [workspace] section. Bounded by "[workspace]" line
# and the next "[anything]" line (or EOF).
ws_start = None
ws_end = len(lines)
for i, line in enumerate(lines):
    if line.strip() == "[workspace]":
        ws_start = i
    elif ws_start is not None and line.lstrip().startswith("["):
        ws_end = i
        break

target_prefix = f"{n} ="
new_line = f'{n} = "{name}"'

if ws_start is None:
    # No section yet — append one (with a blank-line separator
    # if the file doesn't already end on one).
    if lines and lines[-1] != "":
        lines.append("")
    lines.append("[workspace]")
    lines.append(new_line)
else:
    # Strip existing key (if any), keep everything else.
    section = []
    for j in range(ws_start, ws_end):
        line = lines[j]
        if line.lstrip().startswith(target_prefix):
            continue
        section.append(line)
    # Trim trailing blanks before appending so the append point
    # stays clean.
    while section and section[-1].strip() == "":
        section.pop()
    section.append(new_line)
    # Re-introduce one blank line after section if there was one.
    if ws_end < len(lines) and lines[ws_end - 1].strip() == "" \
            and ws_end > ws_start + 1:
        section.append("")
    lines = lines[:ws_start] + section + lines[ws_end:]

sys.stdout.write("\n".join(lines) + "\n")
PY

mv "$TMP" "$CONFIG"
trap - EXIT
echo "$CONFIG: workspace $N = \"$NAME\""
