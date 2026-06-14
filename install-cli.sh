#!/bin/zsh
# Put a `facet` command on your PATH. facet then acts as a thin client
# for the running GUI: `facet --view NAME` / `--hide NAME` /
# `--toggle NAME` / `--theme NAME` / `--quit` / `--reload` post a
# distributed notification and exit (no GUI, no Accessibility needed
# for the client itself). Launch the GUI via run.sh or `open Facet.app`.
#
#   ./install-cli.sh [--dry-run] [--silent]
#   --dry-run  print what would be linked, change nothing
#   --silent   don't tee output to /tmp/install-cli.log (tee is on by default)
set -e
cd "$(dirname "$0")"

DRY_RUN=0; SILENT=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --silent)  SILENT=1 ;;
    -h|--help) echo "usage: $0 [--dry-run] [--silent]"; exit 0 ;;
    *) echo "install-cli: unknown option \"$arg\" (try --dry-run / --silent)" >&2; exit 2 ;;
  esac
done
# Tee stdout+stderr to a log by default so reruns + agent inspection are
# easy (CLAUDE.md: state-changing scripts log by default; --silent opts out).
if (( ! SILENT )); then exec > >(tee "/tmp/install-cli.log") 2>&1; fi

BIN="$PWD/Facet.app/Contents/MacOS/facet"
[[ -x "$BIN" ]] || { echo "build first: ./package.sh"; exit 1; }

# Prefer a dir already on PATH and writable (no dotfile changes):
# Homebrew bin (Apple Silicon, user-owned) → /usr/local/bin → ~/.local/bin.
if [[ -w /opt/homebrew/bin ]]; then
  DIR=/opt/homebrew/bin
elif [[ -w /usr/local/bin ]]; then
  DIR=/usr/local/bin
else
  DIR="$HOME/.local/bin"
fi

if (( DRY_RUN )); then
  echo "[dry-run] would ensure dir exists: $DIR"
  echo "[dry-run] would link: $DIR/facet -> $BIN"
  exit 0
fi

[[ -d "$DIR" ]] || mkdir -p "$DIR"
ln -sf "$BIN" "$DIR/facet"
echo "linked: $DIR/facet -> $BIN"
case ":$PATH:" in
  *":$DIR:"*) : ;;
  *) echo "note: add $DIR to PATH (e.g. in ~/.zshrc)";;
esac
echo "usage: facet --view NAME | --hide NAME | --toggle NAME | --quit | --reload"
echo "       facet --view grid"
echo "       facet --theme cute   # terminal | cute | system"
