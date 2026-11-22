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
# NOTE (v1.0.8 crash fix): Homebrew's prebuilt bottles are compiled on
# the runner's macOS 26 and declare minos 26.0 — libplacebo's bottle
# references std::from_chars, a libc++ symbol added in macOS 14, so the
# app died at launch on 13.7.8. The same applied to every other bottle
# mpv links (dav1d, uchardet, libjpeg, lcms2, shaderc, vulkan loader,
# X11). Everything mpv links is now built from source below with
# -mmacosx-version-min=13.0, and build.sh fails the build if any
# bundled binary still declares minos > 13.0. The 4 X11 bottles are
# dropped entirely (mpv is built with -Dx11=disabled; macOS does not
# need X11). MoltenVK is NOT bundled: its ICD is a separate problem
# (vo=gpu-next finds no Vulkan driver at runtime) — see README.
brew install meson ninja pkg-config nasm autoconf automake libtool cmake

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

cmake_build() {
    # $1 = source dir, rest = extra cmake -D options
    # -DCMAKE_POLICY_VERSION_MINIMUM=3.5: uchardet 0.0.8's
    # CMakeLists requests cmake_minimum_required below 3.5, and the
    # runner's CMake 4.x removed compatibility with CMake < 3.5, so
    # its configure step aborted immediately (run #21). The flag only
    # matters for projects whose minimum is below 3.5; it is
    # harmless for modern ones.
    src="$1"; shift
    (cd "$src" && cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$DEPS" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        "$@" && cmake --build build -j"$(sysctl -n hw.ncpu)" && cmake --install build)
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

# --- v1.0.8: the libraries mpv links, built from source ---
# (Homebrew bottles for these declare minos 26.0; see the brew note
# above.) Order matters: libjpeg-turbo before lcms2 (lcms2 links
# libjpeg), dav1d before FFmpeg (--enable-libdav1d), shaderc stack
# and lcms2 before libplacebo, everything before mpv.
LIBJPEG_TURBO_VERSION="3.1.0"
LIBJPEG_TURBO_URL="https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.1.0/libjpeg-turbo-3.1.0.tar.gz"
LIBJPEG_TURBO_SHA256="9564c72b1dfd1d6fe6274c5f95a8d989b59854575d4bbee44ade7bc17aa9bc93"

LCMS2_VERSION="2.17"
LCMS2_URL="https://github.com/mm2/Little-CMS/releases/download/lcms2.17/lcms2-2.17.tar.gz"
LCMS2_SHA256="d11af569e42a1baa1650d20ad61d12e41af4fead4aa7964a01f93b08b53ab074"

DAV1D_VERSION="1.5.5"
DAV1D_URL="https://code.videolan.org/videolan/dav1d/-/archive/1.5.5/dav1d-1.5.5.tar.bz2"
DAV1D_SHA256="afc5378daba30eafd11d7b4f0ec863270d7b175f38393a2e1e0ff76f3a45c8b9"

UCHARDET_VERSION="0.0.8"
UCHARDET_URL="https://www.freedesktop.org/software/uchardet/releases/uchardet-0.0.8.tar.xz"
UCHARDET_SHA256="e97a60cfc00a1c147a674b097bb1422abd9fa78a2d9ce3f3fdcc2e78a34ac5f0"

VULKAN_VERSION="1.4.313.0"
VULKAN_LOADER_URL="https://github.com/KhronosGroup/Vulkan-Loader/archive/refs/tags/vulkan-sdk-1.4.313.0.tar.gz"
VULKAN_LOADER_SHA256="c736fa79d974c3513f5573b74249ed002aab59f1d15d1c13fc1d00644830869a"
VULKAN_HEADERS_URL="https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/vulkan-sdk-1.4.313.0.tar.gz"
VULKAN_HEADERS_SHA256="20743c99a96c07290f24377360e7a12bdd2c465ba202e0c7ef2ec25d446cf61d"

# libjpeg-turbo (mpv's image writer).
JT_TAR="$BUILD/src/libjpeg-turbo-${LIBJPEG_TURBO_VERSION}.tar.gz"
download "$LIBJPEG_TURBO_URL" "$JT_TAR"
verify_sha256 "$JT_TAR" "$LIBJPEG_TURBO_SHA256" "libjpeg-turbo"
if [ ! -d "$BUILD/src/libjpeg-turbo-${LIBJPEG_TURBO_VERSION}" ]; then
    tar -xzf "$JT_TAR" -C "$BUILD/src"
fi
cmake_build "$BUILD/src/libjpeg-turbo-${LIBJPEG_TURBO_VERSION}" \
    -DENABLE_SHARED=ON -DENABLE_STATIC=OFF -DWITH_JPEG8=ON

# lcms2 (libplacebo's ICC colour management; jpeg on, tiff off).
LC_TAR="$BUILD/src/lcms2-${LCMS2_VERSION}.tar.gz"
download "$LCMS2_URL" "$LC_TAR"
verify_sha256 "$LC_TAR" "$LCMS2_SHA256" "lcms2"
if [ ! -d "$BUILD/src/lcms2-${LCMS2_VERSION}" ]; then
    tar -xzf "$LC_TAR" -C "$BUILD/src"
fi
meson_build "$BUILD/src/lcms2-${LCMS2_VERSION}" \
    -Dtests=disabled -Dtiff=disabled

# dav1d (FFmpeg's AV1 decoder).
D1_TAR="$BUILD/src/dav1d-${DAV1D_VERSION}.tar.bz2"
download "$DAV1D_URL" "$D1_TAR"
verify_sha256 "$D1_TAR" "$DAV1D_SHA256" "dav1d"
if [ ! -d "$BUILD/src/dav1d-${DAV1D_VERSION}" ]; then
    tar -xf "$D1_TAR" -C "$BUILD/src"
fi
meson_build "$BUILD/src/dav1d-${DAV1D_VERSION}" \
    -Denable_tools=false -Denable_tests=false

# uchardet (mpv's subtitle charset detection).
# uchardet 0.0.8's CMakeLists.txt declares cmake_minimum_required
# below 3.5, which CMake 4 on the runner refuses ("Compatibility
# with CMake < 3.5 has been removed from CMake"). Pass the policy
# minimum so the old project still configures (its own minimum is
# honoured by the flag; nothing else in the project changes).
UC_TAR="$BUILD/src/uchardet-${UCHARDET_VERSION}.tar.xz"
download "$UCHARDET_URL" "$UC_TAR"
verify_sha256 "$UC_TAR" "$UCHARDET_SHA256" "uchardet"
if [ ! -d "$BUILD/src/uchardet-${UCHARDET_VERSION}" ]; then
    tar -xf "$UC_TAR" -C "$BUILD/src"
fi
cmake_build "$BUILD/src/uchardet-${UCHARDET_VERSION}" \
    -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

# Vulkan-Headers (the loader's compile-time headers), built from
# source at the same SDK version as the loader.
# Run #22: the loader 1.4.313.0 failed to compile against Homebrew's
# vulkan-headers 1.4.363.0 — the newer headers declare
# PFN_vkCmdDispatchTileQCOM with 2 arguments, while the loader's
# generated code (from its bundled 1.4.313 registry) calls it with
# 1, so loader.c failed with "too few arguments to function call".
# Homebrew's headers drift with every formula update, so pin the
# matching 1.4.313.0 headers here into $DEPS and stop installing
# vulkan-headers from Homebrew (see the brew line above).
VH_TAR="$BUILD/src/Vulkan-Headers-vulkan-sdk-${VULKAN_VERSION}.tar.gz"
download "$VULKAN_HEADERS_URL" "$VH_TAR"
verify_sha256 "$VH_TAR" "$VULKAN_HEADERS_SHA256" "Vulkan-Headers"
if [ ! -d "$BUILD/src/Vulkan-Headers-vulkan-sdk-${VULKAN_VERSION}" ]; then
    tar -xzf "$VH_TAR" -C "$BUILD/src"
fi
cmake_build "$BUILD/src/Vulkan-Headers-vulkan-sdk-${VULKAN_VERSION}"

# Vulkan loader (libplacebo/mpv's Vulkan context; no X11/Wayland WSI
# on macOS; Vulkan-Headers is the matching 1.4.313.0 copy built above
# into $DEPS — CMAKE_PREFIX_PATH puts $DEPS first so the loader is
# configured against those headers, not Homebrew's drifting ones).
VL_TAR="$BUILD/src/Vulkan-Loader-vulkan-sdk-${VULKAN_VERSION}.tar.gz"
download "$VULKAN_LOADER_URL" "$VL_TAR"
verify_sha256 "$VL_TAR" "$VULKAN_LOADER_SHA256" "Vulkan-Loader"
if [ ! -d "$BUILD/src/Vulkan-Loader-vulkan-sdk-${VULKAN_VERSION}" ]; then
    tar -xzf "$VL_TAR" -C "$BUILD/src"
fi
cmake_build "$BUILD/src/Vulkan-Loader-vulkan-sdk-${VULKAN_VERSION}" \
    -DBUILD_SHARED_LIBS=ON -DBUILD_TESTS=OFF \
    -DBUILD_WSI_XCB_SUPPORT=OFF -DBUILD_WSI_XLIB_SUPPORT=OFF \
    -DBUILD_WSI_WAYLAND_SUPPORT=OFF \
    -DCMAKE_PREFIX_PATH="$DEPS;/opt/homebrew"

# --- shaderc stack (libplacebo's GLSL -> SPIR-V compiler) ---
# All four are the Vulkan SDK 1.4.313.0 set, so their versions agree.
# shaderc's CMake builds glslang, SPIRV-Tools and SPIRV-Headers as
# subprojects from its third_party/ dir, so nest the three tarballs
# there instead of installing them separately.
SHADERC_VERSION="2025.3"
SHADERC_URL="https://github.com/google/shaderc/archive/refs/tags/v2025.3.tar.gz"
SHADERC_SHA256="a8e4a25e5c2686fd36981e527ed05e451fcfc226bddf350f4e76181371190937"

GLSLANG_VERSION="1.4.313.0"
GLSLANG_URL="https://github.com/KhronosGroup/glslang/archive/refs/tags/vulkan-sdk-1.4.313.0.tar.gz"
GLSLANG_SHA256="555ac780ccceca926fa25775834639ce6ffc744120bfb68fb8657dd4032d21ee"

SPIRV_TOOLS_VERSION="2025.3"
SPIRV_TOOLS_URL="https://github.com/KhronosGroup/SPIRV-Tools/archive/refs/tags/v2025.3.tar.gz"
SPIRV_TOOLS_SHA256="828f8a2ce2fd7172137af7dbc4a67305d97f63414dd61f0c77d8ede325606c0d"

SPIRV_HEADERS_VERSION="1.4.313.0"
SPIRV_HEADERS_URL="https://github.com/KhronosGroup/SPIRV-Headers/archive/refs/tags/vulkan-sdk-1.4.313.0.tar.gz"
SPIRV_HEADERS_SHA256="f68be549d74afb61600a1e3a7d1da1e6b7437758c8e77d664909f88f302c5ac1"

SC_TAR="$BUILD/src/shaderc-${SHADERC_VERSION}.tar.gz"
download "$SHADERC_URL" "$SC_TAR"
verify_sha256 "$SC_TAR" "$SHADERC_SHA256" "shaderc"
SC_SRC="$BUILD/src/shaderc-${SHADERC_VERSION}"
if [ ! -d "$SC_SRC" ]; then
    tar -xzf "$SC_TAR" -C "$BUILD/src"
fi
GLSLANG_TAR="$BUILD/src/glslang-${GLSLANG_VERSION}.tar.gz"
download "$GLSLANG_URL" "$GLSLANG_TAR"
verify_sha256 "$GLSLANG_TAR" "$GLSLANG_SHA256" "glslang"
if [ ! -f "$SC_SRC/third_party/glslang/CMakeLists.txt" ]; then
    mkdir -p "$SC_SRC/third_party/glslang"
    tar -xzf "$GLSLANG_TAR" -C "$SC_SRC/third_party/glslang" --strip-components=1
fi
SPIRV_TOOLS_TAR="$BUILD/src/SPIRV-Tools-${SPIRV_TOOLS_VERSION}.tar.gz"
download "$SPIRV_TOOLS_URL" "$SPIRV_TOOLS_TAR"
verify_sha256 "$SPIRV_TOOLS_TAR" "$SPIRV_TOOLS_SHA256" "SPIRV-Tools"
if [ ! -f "$SC_SRC/third_party/spirv-tools/CMakeLists.txt" ]; then
    mkdir -p "$SC_SRC/third_party/spirv-tools"
    tar -xzf "$SPIRV_TOOLS_TAR" -C "$SC_SRC/third_party/spirv-tools" --strip-components=1
fi
SPIRV_HEADERS_TAR="$BUILD/src/SPIRV-Headers-${SPIRV_HEADERS_VERSION}.tar.gz"
download "$SPIRV_HEADERS_URL" "$SPIRV_HEADERS_TAR"
verify_sha256 "$SPIRV_HEADERS_TAR" "$SPIRV_HEADERS_SHA256" "SPIRV-Headers"
if [ ! -f "$SC_SRC/third_party/spirv-headers/CMakeLists.txt" ]; then
    mkdir -p "$SC_SRC/third_party/spirv-headers"
    tar -xzf "$SPIRV_HEADERS_TAR" -C "$SC_SRC/third_party/spirv-headers" --strip-components=1
fi
# shaderc's real option is SHADERC_SKIP_TESTS (there is no
# SHADERC_ENABLE_TESTS option — it is an internal variable derived
# from SHADERC_SKIP_TESTS). Passing -DSHADERC_ENABLE_TESTS=OFF was
# silently ignored, so tests stayed enabled and the configure step
# aborted with "gmock was not found - required for tests" (run #23).
# SHADERC_SKIP_TESTS=ON also makes shaderc skip SPIRV-Tools tests,
# and glslang disables its own tests as a subproject.
cmake_build "$SC_SRC" \
    -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON \
    -DCMAKE_PREFIX_PATH="$DEPS;/opt/homebrew"

# --- libplacebo (mpv's gpu-next renderer) ---
# The release tarball ships its 3rdparty/ git submodules EMPTY, and
# the build needs three of them: fast_float (the fallback for
# std::from_chars on old libc++ — see below), jinja2 + markupsafe
# (the GLSL preprocessor imports jinja2 for every build). Vendor
# them from their release tarballs into the source tree.
LIBPLACEBO_VERSION="7.387.0"
LIBPLACEBO_URL="https://code.videolan.org/videolan/libplacebo/-/archive/v${LIBPLACEBO_VERSION}/libplacebo-v${LIBPLACEBO_VERSION}.tar.gz"
LIBPLACEBO_SHA256="3bf5d72786682c194387c33d563872f6bfe202a9816f9dde6535a31a9b2e0d74"

FAST_FLOAT_VERSION="8.4.0"
FAST_FLOAT_URL="https://github.com/fastfloat/fast_float/archive/refs/tags/v${FAST_FLOAT_VERSION}.tar.gz"
FAST_FLOAT_SHA256="0bf4277827259720028bbef6c11d400f07482608bea5952b289baaef6af141a4"

JINJA_VERSION="3.1.6"
JINJA_URL="https://github.com/pallets/jinja/archive/refs/tags/${JINJA_VERSION}.tar.gz"
JINJA_SHA256="2074b22a72caa65474902234b320d73463d6d4c223ee49f4b433495758356337"

MARKUPSAFE_VERSION="3.0.2"
MARKUPSAFE_URL="https://github.com/pallets/markupsafe/archive/refs/tags/${MARKUPSAFE_VERSION}.tar.gz"
MARKUPSAFE_SHA256="cd182103704bfafefce25369fd27f14a5f578f078b7f3ddd1ce2cb940b86403a"

PL_TAR="$BUILD/src/libplacebo-v${LIBPLACEBO_VERSION}.tar.gz"
download "$LIBPLACEBO_URL" "$PL_TAR"
verify_sha256 "$PL_TAR" "$LIBPLACEBO_SHA256" "libplacebo"
PL_SRC="$BUILD/src/libplacebo-v${LIBPLACEBO_VERSION}"
if [ ! -d "$PL_SRC" ]; then
    tar -xzf "$PL_TAR" -C "$BUILD/src"
fi
FF_TAR="$BUILD/src/fast_float-${FAST_FLOAT_VERSION}.tar.gz"
download "$FAST_FLOAT_URL" "$FF_TAR"
verify_sha256 "$FF_TAR" "$FAST_FLOAT_SHA256" "fast_float"
if [ ! -f "$PL_SRC/3rdparty/fast_float/include/fast_float/fast_float.h" ]; then
    mkdir -p "$PL_SRC/3rdparty/fast_float"
    tar -xzf "$FF_TAR" -C "$PL_SRC/3rdparty/fast_float" --strip-components=1
fi
JINJA_TAR="$BUILD/src/jinja-${JINJA_VERSION}.tar.gz"
download "$JINJA_URL" "$JINJA_TAR"
verify_sha256 "$JINJA_TAR" "$JINJA_SHA256" "jinja"
if [ ! -f "$PL_SRC/3rdparty/jinja/src/jinja2/__init__.py" ]; then
    mkdir -p "$PL_SRC/3rdparty/jinja"
    tar -xzf "$JINJA_TAR" -C "$PL_SRC/3rdparty/jinja" --strip-components=1
fi
MS_TAR="$BUILD/src/markupsafe-${MARKUPSAFE_VERSION}.tar.gz"
download "$MARKUPSAFE_URL" "$MS_TAR"
verify_sha256 "$MS_TAR" "$MARKUPSAFE_SHA256" "markupsafe"
if [ ! -f "$PL_SRC/3rdparty/markupsafe/src/markupsafe/__init__.py" ]; then
    mkdir -p "$PL_SRC/3rdparty/markupsafe"
    tar -xzf "$MS_TAR" -C "$PL_SRC/3rdparty/markupsafe" --strip-components=1
fi
# libplacebo's src/convert.cc uses std::from_chars / std::to_chars
# for floating point when the SDK headers declare them — but those
# are libc++ symbols added in macOS 14, so the Homebrew bottle died
# at launch on 13.7.8 with "Symbol not found". The file already has
# an escape hatch for to_chars (HAS_STD_TO_CHARS_FP=0, falling back
# to an in-tree printer); add the same hatch for from_chars (falling
# back to the vendored fast_float above) and define both macros, so
# the built dylib never references either macOS 14-only symbol.
if ! grep -q "HAS_STD_FROM_CHARS_FP" "$PL_SRC/src/convert.cc"; then
    python3 - "$PL_SRC/src/convert.cc" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
anchor = "constexpr bool has_std_from_chars = has_std_from_chars_impl<T>::value;\n"
block = anchor + "\n#if defined(HAS_STD_FROM_CHARS_FP) && HAS_STD_FROM_CHARS_FP == 0\ntemplate <>\nconstexpr bool has_std_from_chars<float>  = false;\ntemplate <>\nconstexpr bool has_std_from_chars<double> = false;\n#endif\n"
assert src.count(anchor) == 1, "convert.cc anchor not found exactly once"
open(path, "w").write(src.replace(anchor, block))
PYEOF
fi
meson_build "$PL_SRC" \
    -Dcpp_args="-DHAS_STD_FROM_CHARS_FP=0 -DHAS_STD_TO_CHARS_FP=0 -mmacosx-version-min=13.0" \
    -Dcpp_link_args="-mmacosx-version-min=13.0" \
    -Dvulkan=enabled -Dshaderc=enabled -Dglslang=disabled \
    -Dopengl=disabled -Dlcms=enabled -Ddovi=disabled \
    -Dlibdovi=disabled -Dxxhash=disabled \
    -Ddemos=false -Dtests=false -Dbench=false

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
    -Dhtml-build=disabled -Dpdf-build=disabled \
    -Dx11=disabled -Dx11-clipboard=disabled -Degl-x11=disabled \
    -Dvdpau-gl-x11=disabled -Dvaapi-x11=disabled
# (v1.0.8: X11 is disabled so mpv no longer links the 4 Homebrew X11
# bottles — libX11, libxcb, libXau, libXdmcp — which declare minos
# 26.0. macOS does not need X11; the native Cocoa video output and
# clipboard are used instead.)
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
