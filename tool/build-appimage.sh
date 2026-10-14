#!/usr/bin/env bash
# Wrap a built Linux bundle in a single-file AppImage.
#
#   flutter build linux --release
#   tool/build-appimage.sh [path/to/bundle] [output.AppImage]
#
# The AppImage carries the app, the Flutter engine and the Rust core. It
# uses the system's GTK 3, and `ffmpeg` for video thumbnails.
#
# Set MPV_BUNDLE to a folder made by tool/build-libmpv-bundle.sh to carry a
# libmpv too, used only when the system has no libmpv.so.2 of its own (no
# mpv installed, or Ubuntu 22.04's older one). Without it, the `mpv` package
# is needed: the app's video player loads it at startup.
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
cp "$root/LICENSE" "$appdir/LICENSE"
cp "$root/linux/packaging/generativeview.desktop" "$appdir/generativeview.desktop"
if [ -n "${MPV_BUNDLE:-}" ]; then
  test -f "$MPV_BUNDLE/libmpv.so.2" || { echo "No libmpv.so.2 in $MPV_BUNDLE" >&2; exit 1; }
  cp -a "$MPV_BUNDLE" "$appdir/mpv"
fi
cat > "$appdir/AppRun" <<'RUN'
#!/bin/sh
here="$(dirname "$(readlink -f "$0")")"
# The system's libmpv if it has one; the one carried here if not.
if [ -d "$here/mpv" ]; then
  have=""
  for ldconfig in ldconfig /sbin/ldconfig /usr/sbin/ldconfig; do
    if command -v "$ldconfig" >/dev/null 2>&1; then
      "$ldconfig" -p 2>/dev/null | grep -q 'libmpv\.so\.2 ' && have=1
      break
    fi
  done
  for dir in /usr/lib /usr/lib64 /usr/lib/x86_64-linux-gnu /usr/local/lib; do
    [ -e "$dir/libmpv.so.2" ] && have=1
  done
  if [ -z "$have" ]; then
    LD_LIBRARY_PATH="$here/mpv${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export LD_LIBRARY_PATH
  fi
fi
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
