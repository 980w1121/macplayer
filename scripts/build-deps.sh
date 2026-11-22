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
    libplacebo dav1d uchardet molten-vk vulkan-headers 2>/dev/null \
    || brew install meson ninja pkg-config nasm autoconf automake libtool \
        libplacebo dav1d uchardet molten-vk

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

# --- Font stack, built from source (v1.0.3 crash fix) ---
# Homebrew's prebuilt bottles for libass/freetype are compiled on the
# runner's macOS 26: freetype is built for macOS 26 and links
# /usr/lib/libhvf.dylib, which does not exist on macOS 13, so the app
# died at launch on 13.7.8. Build the whole font stack from source
# with -mmacosx-version-min=13.0 instead, into $DEPS, so mpv links
# these copies (PKG_CONFIG_PATH puts $DEPS first).
FREETYPE_VERSION="2.13.3"
FREETYPE_URL="https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz"
FREETYPE_SHA256="0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289"

HARFBUZZ_VERSION="11.3.1"
HARFBUZZ_URL="https://github.com/harfbuzz/harfbuzz/releases/download/11.3.1/harfbuzz-11.3.1.tar.xz"
HARFBUZZ_SHA256="d554cca69023178664d36d843af9516e2e2c4c5dfcd117d773a3529f446efa7b"

FRIBIDI_VERSION="1.0.16"
FRIBIDI_URL="https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz"
FRIBIDI_SHA256="1b1cde5b235d40479e91be2f0e88a309e3214c8ab470ec8a2744d82a5a9ea05c"

LIBUNIBREAK_VERSION="6.1"
LIBUNIBREAK_URL="https://github.com/adah1972/libunibreak/releases/download/libunibreak_6_1/libunibreak-6.1.tar.gz"
LIBUNIBREAK_SHA256="cc4de0099cf7ff05005ceabff4afed4c582a736abc38033e70fdac86335ce93f"

LIBASS_VERSION="0.17.4"
LIBASS_URL="https://github.com/libass/libass/releases/download/0.17.4/libass-0.17.4.tar.xz"
LIBASS_SHA256="78f1179b838d025e9c26e8fef33f8092f65611444ffa1bfc0cfac6a33511a05a"

export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig:/opt/homebrew/lib/pkgconfig:/opt/homebrew/share/pkgconfig"

meson_build() {
    # $1 = source dir, rest = extra meson -D options
    src="$1"; shift
    (cd "$src" && meson setup build \
        --prefix="$DEPS" \
        --buildtype=release \
        -Ddefault_library=shared \
        -Dc_args="-mmacosx-version-min=13.0" \
        -Dc_link_args="-mmacosx-version-min=13.0" \
        "$@" && meson compile -C build && meson install -C build)
}

# freetype (no libpng/brotli/bzip2/harfbuzz: keeps it free of extra
# Homebrew bottles; system zlib is fine, it ships with macOS 13).
FT_TAR="$BUILD/src/freetype-${FREETYPE_VERSION}.tar.xz"
download "$FREETYPE_URL" "$FT_TAR"
verify_sha256 "$FT_TAR" "$FREETYPE_SHA256" "freetype"
if [ ! -d "$BUILD/src/freetype-${FREETYPE_VERSION}" ]; then
    tar -xf "$FT_TAR" -C "$BUILD/src"
fi
meson_build "$BUILD/src/freetype-${FREETYPE_VERSION}" \
    -Dpng=disabled -Dzlib=system -Dbrotli=disabled -Dbzip2=disabled \
    -Dharfbuzz=disabled -Dtests=disabled

# harfbuzz (freetype support on; glib/cairo/icu off: no extra bottles).
HB_TAR="$BUILD/src/harfbuzz-${HARFBUZZ_VERSION}.tar.xz"
download "$HARFBUZZ_URL" "$HB_TAR"
verify_sha256 "$HB_TAR" "$HARFBUZZ_SHA256" "harfbuzz"
if [ ! -d "$BUILD/src/harfbuzz-${HARFBUZZ_VERSION}" ]; then
    tar -xf "$HB_TAR" -C "$BUILD/src"
fi
meson_build "$BUILD/src/harfbuzz-${HARFBUZZ_VERSION}" \
    -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled \
    -Dcairo=disabled -Dchafa=disabled -Dicu=disabled \
    -Dtests=disabled -Ddocs=disabled -Dutilities=disabled

# fribidi (skip docs/tools/tests).
FB_TAR="$BUILD/src/fribidi-${FRIBIDI_VERSION}.tar.xz"
download "$FRIBIDI_URL" "$FB_TAR"
verify_sha256 "$FB_TAR" "$FRIBIDI_SHA256" "fribidi"
if [ ! -d "$BUILD/src/fribidi-${FRIBIDI_VERSION}" ]; then
    tar -xf "$FB_TAR" -C "$BUILD/src"
fi
meson_build "$BUILD/src/fribidi-${FRIBIDI_VERSION}" \
    -Ddocs=false -Dbin=false -Dtests=false

# libunibreak (autotools only).
UB_TAR="$BUILD/src/libunibreak-${LIBUNIBREAK_VERSION}.tar.gz"
download "$LIBUNIBREAK_URL" "$UB_TAR"
verify_sha256 "$UB_TAR" "$LIBUNIBREAK_SHA256" "libunibreak"
if [ ! -d "$BUILD/src/libunibreak-${LIBUNIBREAK_VERSION}" ]; then
    tar -xzf "$UB_TAR" -C "$BUILD/src"
fi
(cd "$BUILD/src/libunibreak-${LIBUNIBREAK_VERSION}" && \
    CFLAGS="-mmacosx-version-min=13.0" \
    LDFLAGS="-mmacosx-version-min=13.0" \
    ./configure --prefix="$DEPS" --disable-static --enable-shared && \
    make -j"$(sysctl -n hw.ncpu)" && make install)

# libass (Core Text font provider on macOS, no fontconfig: fontconfig
# would pull another Homebrew bottle; libunibreak on).
LA_TAR="$BUILD/src/libass-${LIBASS_VERSION}.tar.xz"
download "$LIBASS_URL" "$LA_TAR"
verify_sha256 "$LA_TAR" "$LIBASS_SHA256" "libass"
if [ ! -d "$BUILD/src/libass-${LIBASS_VERSION}" ]; then
    tar -xf "$LA_TAR" -C "$BUILD/src"
fi
meson_build "$BUILD/src/libass-${LIBASS_VERSION}" \
    -Dfontconfig=disabled -Dcoretext=enabled -Dlibunibreak=enabled \
    -Dtest=disabled -Dcompare=disabled -Dprofile=disabled \
    -Dfuzz=disabled -Dcheckasm=disabled

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
# libmpv's install name defaults to the absolute build path
# ($PWD/deps/lib/libmpv.2.dylib); the app would then look for it at
# that path on the user's Mac and crash at launch. Point it at @rpath
# so the bundled copy in Contents/Frameworks is used instead.
install_name_tool -id @rpath/libmpv.2.dylib "$DEPS/lib/libmpv.2.dylib"
cd "$ROOT"

echo "--- deps ---"
ls -lh "$DEPS/lib"/libmpv* "$DEPS/lib"/libav* 2>/dev/null | head -20
echo "Done. Now run ./build.sh"
