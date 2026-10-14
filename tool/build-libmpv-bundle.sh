#!/usr/bin/env bash
# Build libmpv (libmpv.so.2) and gather the libraries it needs into one
# folder, for the AppImage to fall back on when the system has no libmpv.so.2
# of its own: Ubuntu 22.04 (which only has libmpv.so.1), or any desktop
# without mpv installed.
#
#   tool/build-libmpv-bundle.sh <out-dir>
#
# Run it on the oldest system the AppImage should start on (CI uses Ubuntu
# 22.04): everything gathered is built against that system's glibc, so it
# also runs on anything newer. Libraries every desktop already has (glibc,
# the graphics drivers, X11, Wayland, sound servers) are left out, following
# the AppImage project's exclude list, so the system's own are used.
set -euo pipefail

out="${1:?usage: $0 <out-dir>}"
mpv_version="${MPV_VERSION:-v0.35.1}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  build-essential git meson ninja-build pkg-config python3 curl patchelf \
  libavcodec-dev libavformat-dev libavutil-dev libavfilter-dev \
  libswscale-dev libswresample-dev libass-dev zlib1g-dev \
  libgl-dev libegl-dev libpulse-dev libasound2-dev

# libmpv alone: no player, no scripting, OpenGL rendering through EGL (what
# media_kit draws with), sound through PulseAudio/PipeWire or ALSA. No
# hardware decoding, which would tie it to the system's driver libraries.
git clone --depth 1 --branch "$mpv_version" https://github.com/mpv-player/mpv.git "$work/mpv"
meson setup "$work/build" "$work/mpv" \
  --buildtype=release --prefix=/usr \
  -Dlibmpv=true -Dcplayer=false -Dtests=false \
  -Dlua=disabled -Djavascript=disabled -Dmanpage-build=disabled \
  -Dgl=enabled -Dplain-gl=enabled -Degl=enabled -Dx11=disabled -Dwayland=disabled -Ddrm=disabled \
  -Dpulse=enabled -Dalsa=enabled -Dpipewire=disabled -Djack=disabled \
  -Dvaapi=disabled -Dvdpau=disabled -Dlibplacebo=disabled \
  -Dlibarchive=disabled -Dlibbluray=disabled -Ddvdnav=disabled -Dcdda=disabled \
  -Duchardet=disabled -Drubberband=disabled -Dlcms2=disabled -Dzimg=disabled \
  -Dvapoursynth=disabled -Dsdl2=disabled -Djpeg=disabled
ninja -C "$work/build"
lib="$(find "$work/build" -maxdepth 1 -name 'libmpv.so.2*' -type f | head -1)"
test -n "$lib"

# The AppImage project's list of libraries to take from the system.
curl -fsSL -o "$work/excludelist" \
  https://raw.githubusercontent.com/AppImageCommunity/pkg2appimage/master/excludelist
excluded() {
  local name="$1"
  grep -v '^#' "$work/excludelist" | sed 's/[[:space:]]*#.*//' | grep -qxF "$name" && return 0
  # Sound servers and the C++ runtime: always the system's.
  case "$name" in
    libpulse*.so*|libasound.so*|libstdc++.so*|libgcc_s.so*|libpipewire*|libsystemd.so*) return 0 ;;
  esac
  return 1
}

mkdir -p "$out"
cp "$lib" "$out/libmpv.so.2"
ldd "$out/libmpv.so.2" | awk '/=> \// { print $1, $3 }' | while read -r name path; do
  if excluded "$name"; then
    continue
  fi
  cp -L "$path" "$out/$name"
done
# Each finds the others beside it.
for f in "$out"/*.so*; do
  patchelf --set-rpath '$ORIGIN' "$f"
done

echo "Bundled into $out:"
ls -1 "$out"
du -sh "$out"
# Nothing it needs may be missing once beside each other.
if LD_LIBRARY_PATH="$out" ldd "$out/libmpv.so.2" | grep 'not found'; then
  echo "libmpv bundle is missing libraries" >&2
  exit 1
fi
