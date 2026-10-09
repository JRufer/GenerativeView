#!/usr/bin/env bash
# Install a built Linux bundle for the current user (no root needed):
#   ~/.local/opt/generativeview        the app
#   ~/.local/bin/generativeview        launcher on PATH
#   ~/.local/share/applications        menu entry
#
#   tool/install-linux.sh [path/to/bundle]
#
# With no argument it installs the bundle it sits in (release downloads ship
# it as bundle/install.sh) or, run from a checkout, the one that
# `flutter build linux --release` makes.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -gt 0 ]; then
  bundle="$1"
elif [ -x "$here/generativeview" ]; then
  bundle="$here"
else
  bundle="$here/../build/linux/x64/release/bundle"
fi
if [ ! -x "$bundle/generativeview" ]; then
  echo "No bundle at $bundle. Build one with: flutter build linux --release" >&2
  exit 1
fi
bundle="$(cd "$bundle" && pwd)"

prefix="${XDG_DATA_HOME:-$HOME/.local/share}"
opt="$HOME/.local/opt/generativeview"
bin="$HOME/.local/bin"

rm -rf "$opt"
mkdir -p "$opt" "$bin" "$prefix/applications" "$prefix/icons/hicolor/256x256/apps"
cp -a "$bundle/." "$opt/"
ln -sf "$opt/generativeview" "$bin/generativeview"

# Desktop entry and icon ship inside release bundles (share/); fall back to
# the source tree when installing straight from a checkout.
desktop="$opt/share/generativeview.desktop"
icon="$opt/share/generativeview.png"
[ -f "$desktop" ] || desktop="$here/../linux/packaging/generativeview.desktop"
[ -f "$icon" ] || icon="$here/../assets/icon.png"
sed "s|^Exec=generativeview|Exec=$opt/generativeview|" "$desktop" > "$prefix/applications/generativeview.desktop"
cp "$icon" "$prefix/icons/hicolor/256x256/apps/generativeview.png"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$prefix/applications" || true

echo "Installed to $opt"
echo "Run it with: generativeview   (make sure $bin is on your PATH)"
