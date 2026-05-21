#!/bin/zsh
# Build a release binary and assemble the .app bundle.
#
# Modes:
#   ./package.sh           release → Facet.app     / com.facet.app
#   ./package.sh --dev     dev     → Facet-dev.app / com.facet.app.dev
#
# Why two flavors: the dev build (run from the repo) and a co-installed
# Homebrew release would otherwise share the same bundle id, so macOS
# would treat them as one app for TCC and the System Settings list
# would show two indistinguishable "facet" entries. The dev variant
# gets its own bundle id + display name "facet (dev)" so each side
# keeps its own Accessibility / Screen Recording grant.
#
# The RELEASE bundle id is com.facet.app — keep it stable across
# versions: macOS keys the Accessibility (TCC) grant + the self-signed
# cert to it.
#
# TCC: ad-hoc signing is not a stable identity → re-grant on every
# rebuild. Persist with a self-signed cert via
# ./setup-signing-cert.sh (writes .signing-id).
set -e
cd "$(dirname "$0")"

MODE="release"
PLIST="Info.plist"
APP="Facet.app"
if [[ "${1:-}" == "--dev" ]]; then
  MODE="dev"; PLIST="Info.plist.dev"; APP="Facet-dev.app"
fi

swift build -c release

# Clean up any prior bundle of either flavor before re-assembling.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$PLIST" "$APP/Contents/Info.plist"
cp .build/release/facet "$APP/Contents/MacOS/facet"   # = CFBundleExecutable

# Identity precedence: $CODESIGN_ID > .signing-id file > ad-hoc ("-").
ID="${CODESIGN_ID:-}"
if [[ -z "$ID" && -f .signing-id ]]; then ID="$(cat .signing-id)"; fi
ID="${ID:--}"
codesign --force --sign "$ID" "$APP"

echo "built $APP  ($MODE, signed: $ID)"
echo "launch: open $APP   |   quit: pkill -f /Contents/MacOS/facet"
