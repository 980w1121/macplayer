#!/bin/sh
# Build the LGPL engine for MacPlayer on a macOS arm64 runner:
#   FFmpeg (LGPL, --disable-gpl) + libmpv (LGPL, meson -Dgpl=false)
# Output: deps/lib/*.dylib and deps/include/ (headers).
# Runtime never depends on Homebrew: the built dylibs are bundled into
# MacPlayer.app/Contents/Frameworks/ by build.sh.
#
# Versions are pinned. SHA256 values measured 2026-11-22 from the
# downloaded tarballs (shasum -a 256 <file>) from ffmpeg.org and
# github.com/mpv-player/mpv archive v0.42.0; the script verifies them.
set -eu
cd "$(dirname "$0")/.."
ROOT="$PWD"

# Minimum macOS for the C libraries too (FFmpeg already passes
# -mmacosx-version-min=13.0 explicitly; libmpv via meson did not,
# so its dylib inherited the build machine's macOS and refused 13.x).
export MACOSX_DEPLOYMENT_TARGET=13.0

FFMPEG_VERSION="7.1.1"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
FFMPEG_SHA256="733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1"

MPV_VERSION="0.42.0"
MPV_URL="https://github.com/mpv-player/mpv/archive/refs/tags/v${MPV_VERSION}.tar.gz"
MPV_SHA256="bcfebbfa2b65a6d88dc97ea18117831072373e38b5785a2afb874ed4df5070dd"

DEPS="$PWD/deps"
BUILD="$PWD/.deps-build"
mkdir -p "$DEPS" "$BUILD" "$BUILD/src"

# Build tools and the libraries mpv needs that are not part of FFmpeg.
# MoltenVK is included because vo=gpu-next + gpu-context=moltenvk needs
# it; whether the macOS runner already ships a usable MoltenVK is an
# unverified point — see README / final report.
brew install meson ninja pkg-config nasm autoconf automake libtool \
    libplacebo libass dav1d uchardet molten-vk vulkan-headers 2>/dev/null \
    || brew install meson ninja pkg-config nasm autoconf automake libtool \
        libplacebo libass dav1d uchardet molten-vk

verify_sha256() {
    file="$1"; expected="$2"; label="$3"
    case "$expected" in
        TODO-*)
            echo "WARNING: $label SHA256 not filled in (placeholder) — skipping verification for $file" >&2
            echo "  Measure it with: shasum -a 256 $file" >&2
            ;;
        *)
            actual="$(shasum -a 256 "$file" | cut -d' ' -f1)"
            if [ "$actual" != "$expected" ]; then
                echo "error: SHA256 mismatch for $file (expected $expected, got $actual)" >&2
                exit 1
            fi
            ;;
    esac
}

download() {
    url="$1"; out="$2"
    if [ ! -f "$out" ]; then
        curl -L --fail -o "$out" "$url"
    fi
}

# --- FFmpeg (LGPL) ---
FFMPEG_TAR="$BUILD/src/ffmpeg-${FFMPEG_VERSION}.tar.xz"
download "$FFMPEG_URL" "$FFMPEG_TAR"
verify_sha256 "$FFMPEG_TAR" "$FFMPEG_SHA256" "FFmpeg"
if [ ! -d "$BUILD/src/ffmpeg-${FFMPEG_VERSION}" ]; then
    tar -xf "$FFMPEG_TAR" -C "$BUILD/src"
fi
cd "$BUILD/src/ffmpeg-${FFMPEG_VERSION}"
./configure \
    --prefix="$DEPS" \
    --arch=arm64 --target-os=darwin \
    --cc=clang \
    --extra-cflags="-arch arm64 -mmacosx-version-min=13.0" \
    --extra-ldflags="-arch arm64 -mmacosx-version-min=13.0" \
    --enable-shared --disable-static --disable-programs \
    --disable-gpl --disable-doc --disable-avdevice \
    --enable-videotoolbox \
    --enable-libdav1d \
    --install-name-dir=@rpath
make -j"$(sysctl -n hw.ncpu)"
make install
cd "$ROOT"

# --- libmpv (LGPL) ---
MPV_TAR="$BUILD/src/mpv-${MPV_VERSION}.tar.gz"
download "$MPV_URL" "$MPV_TAR"
verify_sha256 "$MPV_TAR" "$MPV_SHA256" "mpv"
if [ ! -d "$BUILD/src/mpv-${MPV_VERSION}" ]; then
    tar -xzf "$MPV_TAR" -C "$BUILD/src"
fi
cd "$BUILD/src/mpv-${MPV_VERSION}"
export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig:/opt/homebrew/lib/pkgconfig:/opt/homebrew/share/pkgconfig"
meson setup build \
    --prefix="$DEPS" \
    --buildtype=release \
    -Dc_args="-mmacosx-version-min=13.0" \
    -Dc_link_args="-mmacosx-version-min=13.0" \
    -Dgpl=false \
    -Dlibmpv=true \
    -Ddefault_library=shared \
    -Dcdda=disabled -Ddvdnav=disabled -Dlibarchive=disabled \
    -Dlua=disabled -Djavascript=disabled -Dmanpage-build=disabled \
    -Dhtml-build=disabled -Dpdf-build=disabled
meson compile -C build
meson install -C build
cd "$ROOT"

echo "--- deps ---"
ls -lh "$DEPS/lib"/libmpv* "$DEPS/lib"/libav* 2>/dev/null | head -20
echo "Done. Now run ./build.sh"
