#!/bin/zsh
# Put a `facet` command on your PATH. With --show/--hide/--toggle/
# --view/--theme/--active/--quit it acts as a thin client: posts a
# distributed notification to the running app and exits (no GUI, no
# Accessibility needed for the client itself). Launch the GUI via
# run.sh or `open Facet.app`.
set -e
cd "$(dirname "$0")"
BIN="$PWD/Facet.app/Contents/MacOS/facet"
[[ -x "$BIN" ]] || { echo "build first: ./package.sh"; exit 1; }

# Prefer a dir already on PATH and writable (no dotfile changes):
# Homebrew bin (Apple Silicon, user-owned) → /usr/local/bin → ~/.local/bin.
if [[ -w /opt/homebrew/bin ]]; then
  DIR=/opt/homebrew/bin
elif [[ -w /usr/local/bin ]]; then
  DIR=/usr/local/bin
else
  mkdir -p "$HOME/.local/bin"; DIR="$HOME/.local/bin"
fi
ln -sf "$BIN" "$DIR/facet"
echo "linked: $DIR/facet -> $BIN"
case ":$PATH:" in
  *":$DIR:"*) : ;;
  *) echo "note: add $DIR to PATH (e.g. in ~/.zshrc)";;
esac
echo "usage: facet --show | --hide | --toggle | --active | --quit"
echo "       facet --view=grid"
echo '       facet --theme="terminal" | "cute" | "system"'
