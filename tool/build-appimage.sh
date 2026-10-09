#!/usr/bin/env bash
# Wrap a built Linux bundle in a single-file AppImage.
#
#   flutter build linux --release
#   tool/build-appimage.sh [path/to/bundle] [output.AppImage]
#
# The AppImage carries the app, the Flutter engine and the Rust core. It
# still uses the system's GTK 3 and, for video, libmpv (the `mpv` package)
# and `ffmpeg`.
#
# Needs `appimagetool` on the PATH, or set APPIMAGETOOL to its location; if
# neither is there it is downloaded from the AppImage project's releases.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
bundle="${1:-$root/build/linux/x64/release/bundle}"
out="${2:-$root/GenerativeView-x86_64.AppImage}"

if [ ! -x "$bundle/generativeview" ]; then
  echo "No bundle at $bundle. Build one with: flutter build linux --release" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
appdir="$work/GenerativeView.AppDir"
mkdir -p "$appdir"
cp -a "$bundle" "$appdir/bundle"
rm -f "$appdir/bundle/install.sh"
cp "$root/assets/icon.png" "$appdir/generativeview.png"
cp "$root/linux/packaging/generativeview.desktop" "$appdir/generativeview.desktop"
cat > "$appdir/AppRun" <<'RUN'
#!/bin/sh
here="$(dirname "$(readlink -f "$0")")"
exec "$here/bundle/generativeview" "$@"
RUN
chmod +x "$appdir/AppRun"

tool="${APPIMAGETOOL:-$(command -v appimagetool || true)}"
if [ -z "$tool" ]; then
  tool="$work/appimagetool"
  curl -fsSL -o "$tool" \
    https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
  chmod +x "$tool"
fi

# appimagetool is itself an AppImage; this lets it run where FUSE is missing.
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 "$tool" "$appdir" "$out"
chmod +x "$out"
echo "Wrote $out"
