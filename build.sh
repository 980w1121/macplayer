#!/bin/sh
# Build MacPlayer.app (Apple Silicon arm64 only, unsigned) with swiftc.
# Run scripts/build-deps.sh first so deps/lib/libmpv.dylib exists.
# No Xcode project is used: the app is a plain swiftc build over the
# system frameworks plus the LGPL libmpv built by build-deps.sh.
set -eu
cd "$(dirname "$0")"

# Minimum macOS for the whole app. swiftc without an explicit target
# defaults to the build machine's macOS, which made the v1.0.0 binary
# refuse to run on macOS 13.7.8 ("this version can't be used with this
# version of macOS"). Pin it here; build-deps.sh pins the same for the
# C libraries.
export MACOSX_DEPLOYMENT_TARGET=13.0

if [ ! -f deps/lib/libmpv.dylib ]; then
    echo "error: deps/lib/libmpv.dylib not found — run ./scripts/build-deps.sh first" >&2
    exit 1
fi

APP="MacPlayer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# Compile all Swift sources. -I Sources lets `import CMPV` find
# Sources/CMPV/module.modulemap; -Xcc -I passes the same paths to the
# Clang importer so <mpv/client.h> / <mpv/render.h> resolve from deps.
swiftc -O -whole-module-optimization \
    -target arm64-apple-macos13.0 \
    -I Sources \
    -Xcc -ISources \
    -Xcc -Ideps/include \
    -Xcc -ISources/CMPV \
    -L deps/lib -lmpv \
    -framework AppKit -framework AVFoundation -framework Metal \
    -framework QuartzCore -framework Security -framework CoreMedia \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Sources/MacPlayer/*.swift \
    -o "$APP/Contents/MacOS/MacPlayer"

cp Info.plist "$APP/Contents/Info.plist"

# Bundle libmpv and every dylib it links against that lives in deps/lib
# or in the Homebrew prefix used at build time, and rewrite their
# install names to @rpath so the app never depends on Homebrew at runtime.
copy_dylib() {
    src="$1"
    base="$(basename "$src")"
    if [ ! -f "$APP/Contents/Frameworks/$base" ]; then
        cp -f "$src" "$APP/Contents/Frameworks/$base" 2>/dev/null || true
        chmod +w "$APP/Contents/Frameworks/$base" 2>/dev/null || true
        install_name_tool -id "@rpath/$base" "$APP/Contents/Frameworks/$base" 2>/dev/null || true
    fi
}
for lib in deps/lib/*.dylib; do
    [ -e "$lib" ] || continue
    copy_dylib "$lib"
done
# One pass over the bundled dylibs is not enough: a newly copied
# Homebrew dylib (e.g. libX11) may itself link to another Homebrew
# dylib (e.g. libXext), so copy to a fixpoint — repeat until a pass
# adds nothing. Note the paths are /opt/homebrew/opt/<formula>/lib/…,
# not /opt/homebrew/lib/ — the v1.0.2 run #10 failed exactly because
# the old grep only matched /opt/homebrew/lib/ and libavcodec kept
# absolute /opt/homebrew/opt/ references to libdav1d and libX11.
while :; do
    before="$(ls "$APP/Contents/Frameworks" | wc -l)"
    for bundled in "$APP"/Contents/Frameworks/*.dylib; do
        [ -e "$bundled" ] || continue
        otool -L "$bundled" 2>/dev/null | awk '{print $1}' | grep '^/opt/homebrew/.*\.dylib$' | while read -r dep; do
            copy_dylib "$dep"
        done
    done
    after="$(ls "$APP/Contents/Frameworks" | wc -l)"
    [ "$after" = "$before" ] && break
done
# Rewrite @rpath references inside the bundled dylibs to the new location.
# NOTE (run #11): the old grep was '^(@rpath|/opt/homebrew/|/Users/|deps/lib)/'
# — the trailing '/' sat outside the group, so it demanded a double
# slash ('/opt/homebrew//', '@rpath//') and matched nothing, leaving
# absolute Homebrew paths in e.g. libass.9.dylib (freetype, fribidi,
# harfbuzz, libunibreak). The '/' now belongs inside each alternative.
for bundled in "$APP"/Contents/Frameworks/*.dylib; do
    [ -e "$bundled" ] || continue
    otool -L "$bundled" 2>/dev/null | awk '{print $1}' | grep -E '^(@rpath/|/opt/homebrew/|/Users/|deps/lib/)' | while read -r dep; do
        base="$(basename "$dep")"
        install_name_tool -change "$dep" "@rpath/$base" "$bundled" 2>/dev/null || true
    done
done

# Rewrite the executable's own load commands: linking against
# deps/lib/libmpv.dylib recorded libmpv's install name as the absolute
# build-machine path (/Users/runner/.../libmpv.2.dylib), so on any other
# Mac dyld aborted at launch with "Library not loaded: libmpv.2.dylib"
# (v1.0.1 crash on macOS 13.7.8). Point every non-system, non-@rpath
# dylib the executable links to at @rpath/<basename> instead.
otool -L "$APP/Contents/MacOS/MacPlayer" | awk '{print $1}' | grep '\.dylib$' | grep -v -E '^(@rpath|/usr/lib/|/System/)' | while read -r dep; do
    base="$(basename "$dep")"
    install_name_tool -change "$dep" "@rpath/$base" "$APP/Contents/MacOS/MacPlayer"
done

# Bundle the Swift runtime (v1.0.4 crash fix).
# mpv 0.42's macOS backend is written in Swift (osdep/mac/*.swift,
# video/out/mac/*.swift), so libmpv.2.dylib links against the Swift
# runtime. The macOS 26 runner's Swift 6.2 compiler emits a reference
# to _$ss20__StaticArrayStorageCN, a symbol that does not exist in
# macOS 13.7.8's system libswiftCore (Swift 5.9), so dyld aborts at
# launch with "Symbol not found". The standard fix — the same one
# Xcode applies as "Embed Swift Standard Libraries" — is to ship the
# toolchain's Swift runtime dylibs inside the app and point every
# reference at @rpath instead of /usr/lib/swift/.
# Xcode 26.6 moved libswift_Concurrency.dylib out of usr/lib/swift/macosx
# (run #15 failed here: "Swift runtime libswift_Concurrency.dylib not
# found in .../usr/lib/swift/macosx"). Swift 6.2 still builds it as a
# separate dylib, so look for each runtime lib in the current-runtime dir
# first, then the back-deployment dir (where Xcode's swift-stdlib-tool
# embeds from for old deployment targets), then anywhere under the
# toolchain (macOS copies only), then the runner's system runtime
# as a last resort.
# NOTE (run #16): `xcrun --find swiftc` is
# .../XcodeDefault.xctoolchain/usr/bin/swiftc, so dirname/.. is the
# toolchain's usr/ dir, NOT the toolchain root — the previous fix
# appended another /usr (.../usr/usr/lib/swift/macosx), a path that
# does not exist, so the search never looked in the real dirs.
TOOLCHAIN_DIR="$(cd "$(dirname "$(xcrun --find swiftc)")/.." && pwd)"
SWIFT_LIB_DIR="$TOOLCHAIN_DIR/lib/swift/macosx"
SWIFT_LIB_DIR_BACKDEPLOY="$TOOLCHAIN_DIR/lib/swift-5.0/macosx"
find_swift_lib() {
    name="$1"
    for dir in "$SWIFT_LIB_DIR" "$SWIFT_LIB_DIR_BACKDEPLOY"; do
        if [ -f "$dir/$name" ]; then
            echo "$dir/$name"
            return 0
        fi
    done
    found="$(find "$TOOLCHAIN_DIR" -path '*macosx*' -name "$name" -print -quit 2>/dev/null)"
    if [ -n "$found" ]; then
        echo "$found"
        return 0
    fi
    if [ -f "/usr/lib/swift/$name" ]; then
        echo "/usr/lib/swift/$name"
        return 0
    fi
    return 1
}
copy_swift_lib() {
    name="$1"
    if [ ! -f "$APP/Contents/Frameworks/$name" ]; then
        src="$(find_swift_lib "$name")" || { echo "error: Swift runtime $name not found in $SWIFT_LIB_DIR, $SWIFT_LIB_DIR_BACKDEPLOY, or the toolchain" >&2; exit 1; }
        echo "bundling Swift runtime $name from $src"
        cp -f "$src" "$APP/Contents/Frameworks/$name"
        chmod +w "$APP/Contents/Frameworks/$name"
        install_name_tool -id "@rpath/$name" "$APP/Contents/Frameworks/$name"
        # A system-sourced runtime lib is built for the runner's macOS;
        # refuse it if it demands a newer macOS than our 13.0 target,
        # or the app would die at launch on the user's Mac.
        if [ "$src" = "/usr/lib/swift/$name" ]; then
            minos="$(otool -l "$APP/Contents/Frameworks/$name" | awk '/LC_BUILD_VERSION/{p=1} p&&/minos/{print $2; exit} /LC_VERSION_MIN_MACOSX/{q=1} q&&/version/{print $2; exit}')"
            major="${minos%%.*}"
            case "$major" in
                ''|*[!0-9]*) : ;;
                *) if [ "$major" -gt 13 ]; then echo "error: system Swift runtime $name requires macOS $minos (> 13.0)" >&2; exit 1; fi ;;
            esac
        fi
    fi
}
# Repeat to a fixpoint: a newly copied Swift dylib may itself link
# another Swift dylib (e.g. libswiftFoundation links libswiftCore).
SWIFT_DEPS_TMP="/tmp/macplayer-swift-deps.$$"
while :; do
    before="$(ls "$APP/Contents/Frameworks" | wc -l)"
    : > "$SWIFT_DEPS_TMP"
    for binary in "$APP/Contents/MacOS/MacPlayer" "$APP"/Contents/Frameworks/*.dylib; do
        [ -e "$binary" ] || continue
        otool -L "$binary" 2>/dev/null | awk '{print $1}' | grep '^/usr/lib/swift/.*\.dylib$' >> "$SWIFT_DEPS_TMP" || true
    done
    for dep in $(sort -u "$SWIFT_DEPS_TMP"); do
        copy_swift_lib "$(basename "$dep")"
    done
    after="$(ls "$APP/Contents/Frameworks" | wc -l)"
    [ "$after" = "$before" ] && break
done
rm -f "$SWIFT_DEPS_TMP"
# Rewrite every /usr/lib/swift/ reference in the executable and all
# bundled dylibs (including the Swift dylibs themselves, which
# reference each other by absolute path) to @rpath/<basename>.
for binary in "$APP/Contents/MacOS/MacPlayer" "$APP"/Contents/Frameworks/*.dylib; do
    [ -e "$binary" ] || continue
    otool -L "$binary" 2>/dev/null | awk '{print $1}' | grep '^/usr/lib/swift/.*\.dylib$' | while read -r dep; do
        base="$(basename "$dep")"
        install_name_tool -change "$dep" "@rpath/$base" "$binary" 2>/dev/null || true
    done
done

# App icon: build MacPlayer.icns from assets/MacPlayer-icon-1024.png
# (1024x1024) with sips + iconutil, if the source PNG is present.
if [ -f assets/MacPlayer-icon-1024.png ]; then
    ICONSET="$(mktemp -d)/MacPlayer.iconset"
    mkdir -p "$ICONSET"
    sips -z 16 16     assets/MacPlayer-icon-1024.png --out "$ICONSET/icon_16x16.png" >/dev/null
    sips -z 32 32     assets/MacPlayer-icon-1024.png --out "$ICONSET/icon_16x16@2x.png" >/dev/null
    sips -z 32 32     assets/MacPlayer-icon-1024.png --out "$ICONSET/icon_32x32.png" >/dev/null
    sips -z 64 64     assets/MacPlayer-icon-1024.png --out "$ICONSET/icon_32x32@2x.png" >/dev/null
    sips -z 128 128   assets/MacPlayer-icon-1024.png --out "$ICONSET/icon_128x128.png" >/dev/null
    sips -z 256 256   assets/MacPlayer-icon-1024.png --out "$ICONSET/icon_128x128@2x.png" >/dev/null
    sips -z 256 256   assets/MacPlayer-icon-1024.png --out "$ICONSET/icon_256x256.png" >/dev/null
    sips -z 512 512   assets/MacPlayer-icon-1024.png --out "$ICONSET/icon_256x256@2x.png" >/dev/null
    sips -z 512 512   assets/MacPlayer-icon-1024.png --out "$ICONSET/icon_512x512.png" >/dev/null
    sips -z 1024 1024 assets/MacPlayer-icon-1024.png --out "$ICONSET/icon_512x512@2x.png" >/dev/null
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/MacPlayer.icns"
    rm -rf "$(dirname "$ICONSET")"
fi

# Ad-hoc re-sign (no paid certificate): install_name_tool edits above
# invalidate the dylibs' original signatures, and macOS 13 kills the
# app at launch with "Code Signature Invalid" when a dependent dylib
# fails validation (v1.0.2 crash). Re-sign every modified binary and
# the bundle itself after all edits, then verify below.
for f in "$APP"/Contents/Frameworks/*.dylib; do
    [ -e "$f" ] || continue
    codesign --force --sign - --timestamp=none "$f"
done
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/MacPlayer"
codesign --force --sign - --timestamp=none "$APP"

echo "--- checks ---"
file "$APP/Contents/MacOS/MacPlayer"
lipo -info "$APP/Contents/MacOS/MacPlayer"
# Guard: the binary must declare minos 13.0, or macOS 13 refuses it.
# otool prints minos on the 3rd line after "cmd LC_BUILD_VERSION"
# (cmdsize, platform, minos), so -A3 is required — -A2 never saw
# the minos line and failed even when minos was correct (run #8).
otool -l "$APP/Contents/MacOS/MacPlayer" | grep -A3 LC_BUILD_VERSION | grep -q "minos 13.0" \
    || { echo "error: MacPlayer minos is not 13.0" >&2; otool -l "$APP/Contents/MacOS/MacPlayer" | grep -A3 LC_BUILD_VERSION >&2; exit 1; }
# Guard: the ad-hoc signature must verify, or macOS kills the app at
# launch with "Code Signature Invalid" (v1.0.2 crash).
codesign --verify --deep "$APP" || { echo "error: codesign verify failed" >&2; exit 1; }
# Guard: no bundled binary may link a macOS 26-only system library
# (v1.0.3 crash: Homebrew's freetype linked /usr/lib/libhvf.dylib,
# which does not exist on macOS 13), and none may still point at the
# system Swift runtime (v1.0.4 crash: libmpv needs a Swift 6.2 symbol
# missing from macOS 13's libswiftCore — the runtime must be bundled).
# Fail loudly in CI instead of shipping an app that dies at launch.
for f in "$APP/Contents/MacOS/MacPlayer" "$APP"/Contents/Frameworks/*.dylib; do
    [ -e "$f" ] || continue
    if otool -L "$f" | grep -q '/usr/lib/libhvf\.dylib'; then
        echo "error: $f links /usr/lib/libhvf.dylib (macOS 26-only)" >&2
        exit 1
    fi
    if otool -L "$f" | grep -q '/usr/lib/swift/'; then
        echo "error: $f still links the system Swift runtime" >&2
        exit 1
    fi
done
# Report every bundled binary's minimum macOS for the build log.
echo "--- bundled binaries: minimum macOS ---"
for f in "$APP/Contents/MacOS/MacPlayer" "$APP"/Contents/Frameworks/*.dylib; do
    [ -e "$f" ] || continue
    minos="$(otool -l "$f" | awk '/LC_BUILD_VERSION/{p=1} p&&/minos/{print $2; exit} /LC_VERSION_MIN_MACOSX/{q=1} q&&/version/{print $2; exit}')"
    echo "$(basename "$f"): minos ${minos:-unknown}"
done
# Guard: the icon must be present when its source PNG is shipped.
if [ -f assets/MacPlayer-icon-1024.png ]; then
    test -f "$APP/Contents/Resources/MacPlayer.icns" || { echo "error: MacPlayer.icns missing" >&2; exit 1; }
fi
# Guard: no absolute build-machine or Homebrew path may remain in the
# executable's load commands, or the app dies at launch on other Macs.
if otool -L "$APP/Contents/MacOS/MacPlayer" | grep -E '/Users/|/opt/homebrew/'; then
    echo "error: absolute dylib path remains in MacPlayer executable" >&2
    otool -L "$APP/Contents/MacOS/MacPlayer" >&2
    exit 1
fi
# Same guard for every bundled dylib: none may point at the build
# machine's paths, or the app dies at launch on other Macs.
for bundled in "$APP"/Contents/Frameworks/*.dylib; do
    [ -e "$bundled" ] || continue
    if otool -L "$bundled" | grep -E '/Users/|/opt/homebrew/'; then
        echo "error: absolute dylib path remains in $bundled" >&2
        otool -L "$bundled" >&2
        exit 1
    fi
done
ls -lh "$APP/Contents/Frameworks/" | head -30
echo "Built: $APP"
