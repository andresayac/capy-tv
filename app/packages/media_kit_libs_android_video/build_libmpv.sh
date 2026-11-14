#!/bin/bash
# Builds libmpv for Android anew, with the libraries under it brought up to date, and leaves in
# android/libs the jars this plugin ships: media-kit's own (v1.1.7, of 2023), each with its
# libmpv.so replaced. mpv itself stays at the commit media_kit uses. Run in Linux or WSL:
#
#   WORK=/var/tmp/capy-build bash build_libmpv.sh          # all three ABIs, then the jars
#   WORK=/var/tmp/capy-build bash build_libmpv.sh arm64    # one (all those built are packed)
#
# It uses media-kit's build scripts (libmpv-android-video-build), changed here: the versions below,
# mbedTLS with its submodules, no sudo, and FFmpeg's patches fitted to 6.1 (its HLS seek fix is in
# 6.1 already). Needs git, make, cmake, ninja, autotools, pkg-config, wget, zip and a JDK; meson,
# jinja2 and nasm are set up in $WORK. The first run downloads the Android SDK and NDK (~2 GB).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-/var/tmp/capy-build}
REPO=$WORK/libmpv-android-video-build
UPSTREAM=1ecf5100ec0f75e1d0630f48851b85769c92eed2 # its main of 2026-01-27 (v1.1.11)
if [ $# -gt 0 ]; then ARCHS=("$@"); else ARCHS=(arm64 armv7l x86_64); fi

# The versions: each the newest of its line when built (2026-11-13). FFmpeg stays on 6.1, which
# the mpv of media_kit builds with and which still gets fixes; 7.x would need a newer mpv
VERSIONS=(
  v_ffmpeg=6.1.6
  v_mbedtls=3.6.7
  v_freetype=2-14-3
  v_libxml2=2.14.6
  v_harfbuzz=11.5.1
  v_libass=0.17.4
  v_fribidi=1.0.16
  v_dav1d=1.5.3
)

mkdir -p "$WORK/tools"
if [ ! -x "$WORK/tools-venv/bin/meson" ]; then
  python3 -m venv "$WORK/tools-venv"
  "$WORK/tools-venv/bin/pip" install -q meson jinja2 jsonschema
fi
NASM=$WORK/tools/nasm-2.16.03
if [ ! -x "$NASM/nasm" ]; then
  (cd "$WORK/tools" && wget -q https://www.nasm.us/pub/nasm/releasebuilds/2.16.03/nasm-2.16.03.tar.xz &&
    tar xf nasm-2.16.03.tar.xz && cd nasm-2.16.03 && ./configure -q && make -j"$(nproc)" >/dev/null)
fi
export PATH=$WORK/tools-venv/bin:$NASM:$PATH
export TRAVIS=1 # download-sdk.sh: no apt, the tools are above

[ -d "$REPO" ] || git clone -q https://github.com/media-kit/libmpv-android-video-build.git "$REPO"
cd "$REPO"
# At that commit, whatever main has now; a run before left its changes on it, which stay
[ "$(git rev-parse HEAD)" = "$UPSTREAM" ] || git checkout -q -B capy "$UPSTREAM"
cd buildscripts

for v in "${VERSIONS[@]}"; do sed -i "s/^${v%%=*}=.*/$v/" include/depinfo.sh; done
sed -i 's#git clone --depth 1 --branch v$v_mbedtls #git clone --depth 1 --recursive --shallow-submodules --branch v$v_mbedtls #' include/download-deps.sh
sed -i 's/sudo chmod +x \$BUILDSCRIPT/chmod +x $BUILDSCRIPT/' build.sh
# libxml2 2.14's autogen.sh runs configure itself, not cross: only its files are wanted
sed -i 's#^\[ -f configure \] || ./autogen.sh#[ -f configure ] || NOCONFIGURE=1 ./autogen.sh#' scripts/libxml2.sh

[ -d deps/mpv ] || ./download.sh

# FFmpeg's patches, on 6.1: its DASH one moved 11 lines, its HLS one is in FFmpeg already
if [ -f patches/ffmpeg/hls_mp4_seek.patch ]; then
  git rm -q patches/ffmpeg/hls_mp4_seek.patch
  (cd deps/ffmpeg && git reset -q --hard && patch -s -p1 <../../patches/ffmpeg/dash_base_url_escape.patch &&
    git diff >../../patches/ffmpeg/dash_base_url_escape.patch && git reset -q --hard)
fi
./patch.sh
cp flavors/default.sh scripts/ffmpeg.sh

. ./include/depinfo.sh
STRIP=./sdk/android-sdk-linux/ndk/$v_ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip
abi_of() { case "$1" in arm64) echo arm64-v8a ;; armv7l) echo armeabi-v7a ;; *) echo "$1" ;; esac; }

for arch in "${ARCHS[@]}"; do
  ./build.sh --arch "$arch"
  "$STRIP" --strip-all "prefix/$(abi_of "$arch")/usr/local/lib/libmpv.so"
done
# The jars, of every ABI built (now or before): media-kit's v1.1.7 ones (its Android helper library
# as it was), libmpv.so replaced
declare -A MD5=(
  [arm64-v8a]=83df25b61193af8fa815e373143ac9af
  [armeabi-v7a]=22e21526fefc0a2b8f17adbec9f57590
  [x86_64]=6fa26bf0459b11f1c0b0dbc29e5b940d
)
mkdir -p "$WORK/jars-v117" "$HERE/android/libs"
for abi in arm64-v8a armeabi-v7a x86_64; do
  [ -f "prefix/$abi/usr/local/lib/libmpv.so" ] || continue
  jar=$WORK/jars-v117/default-$abi.jar
  [ -f "$jar" ] || wget -q -O "$jar" "https://github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.7/default-$abi.jar"
  [ "$(md5sum "$jar" | cut -d' ' -f1)" = "${MD5[$abi]}" ] || { echo "MD5 mismatch: $jar" >&2; exit 1; }
  pack=$(mktemp -d)
  mkdir -p "$pack/lib/$abi"
  cp "prefix/$abi/usr/local/lib/libmpv.so" "$pack/lib/$abi/"
  cp "$jar" "$HERE/android/libs/default-$abi.jar"
  (cd "$pack" && zip -q "$HERE/android/libs/default-$abi.jar" "lib/$abi/libmpv.so")
  rm -rf "$pack"
done
(cd "$HERE/android/libs" && md5sum ./*.jar)
