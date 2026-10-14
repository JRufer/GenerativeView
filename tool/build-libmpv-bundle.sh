#!/usr/bin/env bash
# Build a playback-only libmpv (libmpv.so.2) and gather the libraries it
# needs into one folder, for the AppImage to fall back on when the system has
# no libmpv.so.2 of its own: Ubuntu 22.04 (which only has libmpv.so.1), or
# any desktop without mpv installed.
#
#   tool/build-libmpv-bundle.sh <out-dir>
#
# Kept as small as it can be: FFmpeg is built here with nothing but what the
# app plays (H.264, H.265, VP8, VP9, AV1 and ProRes video; AAC, Opus,
# Vorbis, MP3, FLAC and PCM sound; in MP4/MOV/M4V or WebM/MKV), no encoders,
# no network, no devices. Its libraries get their own names (libavcodec_gv…)
# so they never stand in for the system's FFmpeg, which the app runs for
# video thumbnails.
#
# Run it on the oldest system the AppImage should start on (CI uses Ubuntu
# 22.04): everything is built against that system's glibc, so it also runs
# on anything newer. Libraries every desktop already has (glibc, graphics,
# fonts, sound servers) are left out, following the AppImage project's
# exclude list, so the system's own are used.
#
# Set SKIP_APT=1 when the build tools are already installed.
set -euo pipefail

out="$(realpath -m "${1:?usage: $0 <out-dir>}")"
mpv_version="${MPV_VERSION:-v0.35.1}"
ffmpeg_version="${FFMPEG_VERSION:-n5.1.6}"
dav1d_version="${DAV1D_VERSION:-1.4.3}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
prefix="$work/prefix"
jobs="$(nproc)"

if [ -z "${SKIP_APT:-}" ]; then
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends \
    build-essential git ninja-build pkg-config python3 python3-pip curl patchelf nasm \
    libass-dev libgl-dev libegl-dev libpulse-dev libasound2-dev
  # mpv and dav1d want a newer meson than Ubuntu 22.04 has.
  pip3 install --user 'meson>=1.2,<2'
  export PATH="$HOME/.local/bin:$PATH"
fi
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

# --- dav1d (AV1), static, folded into libavcodec ---------------------------
git clone -q --depth 1 --branch "$dav1d_version" https://github.com/videolan/dav1d.git "$work/dav1d"
meson setup "$work/dav1d-build" "$work/dav1d" \
  --buildtype=release --prefix="$prefix" --libdir=lib \
  -Ddefault_library=static -Db_staticpic=true \
  -Denable_tools=false -Denable_tests=false -Denable_examples=false
ninja -C "$work/dav1d-build" install

# --- FFmpeg: decoding only ------------------------------------------------
git clone -q --depth 1 --branch "$ffmpeg_version" https://github.com/FFmpeg/FFmpeg.git "$work/ffmpeg"
(
  cd "$work/ffmpeg"
  ./configure \
    --prefix="$prefix" --libdir="$prefix/lib" \
    --enable-shared --disable-static --enable-pic --build-suffix=_gv \
    --disable-programs --disable-doc --disable-debug --disable-network \
    --disable-autodetect --disable-everything \
    --disable-avdevice --disable-postproc \
    --enable-avcodec --enable-avformat --enable-avfilter --enable-swscale --enable-swresample \
    --enable-libdav1d \
    --enable-protocol=file \
    --enable-demuxer=mov,matroska \
    --enable-decoder=h264,hevc,vp8,vp9,libdav1d,prores,mpeg4 \
    --enable-decoder=aac,aac_latm,opus,vorbis,mp3,mp3float,flac,alac \
    --enable-decoder=pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_f32le \
    --enable-parser=h264,hevc,vp8,vp9,av1,mpeg4video,aac,aac_latm,opus,vorbis,mpegaudio,flac \
    --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,vp9_superframe_split,av1_frame_split,extract_extradata \
    --enable-filter=scale,format,aformat,aresample,anull,null,volume,hflip,vflip,transpose,rotate,crop,pad,setsar,fps,abuffer,abuffersink,buffer,buffersink
  make -j"$jobs"
  make install
)
# The libraries are named libavcodec_gv and so on, and so are their
# pkg-config files; mpv asks for libavcodec, so give it that name too.
for pc in "$prefix"/lib/pkgconfig/lib*_gv.pc; do
  cp "$pc" "${pc%_gv.pc}.pc"
done

# --- libmpv alone: no player, no scripting ---------------------------------
# OpenGL rendering through any context (what media_kit draws with), sound
# through PulseAudio/PipeWire or ALSA. No hardware decoding, which would tie
# it to the system's driver libraries.
git clone -q --depth 1 --branch "$mpv_version" https://github.com/mpv-player/mpv.git "$work/mpv"
meson setup "$work/mpv-build" "$work/mpv" \
  --buildtype=release --prefix=/usr \
  -Dlibmpv=true -Dcplayer=false -Dtests=false \
  -Dlua=disabled -Djavascript=disabled -Dmanpage-build=disabled \
  -Dgl=enabled -Dplain-gl=enabled -Degl=enabled -Dx11=disabled -Dwayland=disabled -Ddrm=disabled \
  -Dpulse=enabled -Dalsa=enabled -Dpipewire=disabled -Djack=disabled \
  -Dvaapi=disabled -Dvdpau=disabled -Dlibplacebo=disabled -Dlibavdevice=disabled \
  -Dlibarchive=disabled -Dlibbluray=disabled -Ddvdnav=disabled -Dcdda=disabled -Ddvbin=disabled \
  -Duchardet=disabled -Drubberband=disabled -Dlcms2=disabled -Dzimg=disabled \
  -Dvapoursynth=disabled -Dsdl2=disabled -Djpeg=disabled -Diconv=disabled
ninja -C "$work/mpv-build"
lib="$(find "$work/mpv-build" -maxdepth 1 -name 'libmpv.so.2*' -type f | head -1)"
test -n "$lib"

# --- gather ----------------------------------------------------------------
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

rm -rf "$out"
mkdir -p "$out"
cp "$lib" "$out/libmpv.so.2"
LD_LIBRARY_PATH="$prefix/lib" ldd "$out/libmpv.so.2" | awk '/=> \// { print $1, $3 }' | while read -r name path; do
  if excluded "$name"; then
    continue
  fi
  cp -L "$path" "$out/$name"
done
# Each finds the others beside it; nothing kept that only helps debugging.
for f in "$out"/*.so*; do
  chmod u+w "$f"
  strip --strip-unneeded "$f"
  patchelf --set-rpath '$ORIGIN' "$f"
done

echo "Bundled into $out:"
ls -la "$out"
du -sh "$out"
# Nothing it needs may be missing once beside each other.
if ldd "$out/libmpv.so.2" | grep 'not found'; then
  echo "libmpv bundle is missing libraries" >&2
  exit 1
fi
# And none of it stands in for the system's own FFmpeg.
if ls "$out" | grep -E '^lib(avcodec|avformat|avutil|avfilter|swscale|swresample)\.so'; then
  echo "an unrenamed FFmpeg library slipped into the bundle" >&2
  exit 1
fi
