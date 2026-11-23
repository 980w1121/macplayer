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

# Guard: the plural openFiles: [String] delegate method must never
# come back (v1.0.8 crash: AppKit passes NSURL objects on macOS 13,
# and the NSArray-to-[String] force-cast aborts before our code
# runs). The fix is the modern openURLs: [URL] (NSURL bridges to
# URL safely) plus the singular openFile: as a fallback — the same
# shape IINA uses. Fail fast here, before compiling, instead of
# shipping an app that dies the first time the system hands it a file.
if grep -rn 'func application.*openFiles' Sources/; then
    echo "error: plural openFiles delegate method found — use openURLs: [URL] / singular openFile: instead (v1.0.8 crash)" >&2
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
# NOTE (v1.0.6 crash): the Xcode 26.6 back-deployment dir
# (swift-5.0/macosx) ships THIN x86_64-only runtime libs — 16 of the 17
# bundled Swift libs were Intel-only, so dyld on Apple Silicon refused
# them with "incompatible architecture (have 'x86_64', need 'arm64')".
# The real arm64 Swift 6.2 runtime comes from the swift.org Swift 6.2
# toolchain (installed by release.yml into
# /Library/Developer/Toolchains/swift-6.2-RELEASE.xctoolchain, or any
# path in $SWIFT_ORG_RUNTIME_DIR), so search that FIRST, and never
# accept a candidate without an arm64 slice — an x86_64-only lib is
# skipped and the search continues instead of being bundled.
# NOTE (run #16): `xcrun --find swiftc` is
# .../XcodeDefault.xctoolchain/usr/bin/swiftc, so dirname/.. is the
# toolchain's usr/ dir, NOT the toolchain root — the previous fix
# appended another /usr (.../usr/usr/lib/swift/macosx), a path that
# does not exist, so the search never looked in the real dirs.
# NOTE (run #17): Xcode 26.6 no longer ships libswiftCoreMIDI.dylib
# anywhere in the toolchain, and the macOS 26 runner's /usr/lib/swift
# lacks it too — the CoreMIDI Swift overlay was dropped. A bundled
# overlay still references it, so copy_swift_lib skips libraries
# that cannot be found instead of failing, their references are left
# pointing at /usr/lib/swift/ (macOS 13 still ships the library
# there), and the guard below only fails on references to libraries
# that ARE bundled (a missed @rpath rewrite).
TOOLCHAIN_DIR="$(cd "$(dirname "$(xcrun --find swiftc)")/.." && pwd)"
SWIFT_LIB_DIR="$TOOLCHAIN_DIR/lib/swift/macosx"
SWIFT_LIB_DIR_BACKDEPLOY="$TOOLCHAIN_DIR/lib/swift-5.0/macosx"
SWIFT_ORG_RUNTIME_DIR="${SWIFT_ORG_RUNTIME_DIR:-/Library/Developer/Toolchains/swift-6.2-RELEASE.xctoolchain/usr/lib/swift/macosx}"
has_arm64() {
    lipo -archs "$1" 2>/dev/null | grep -qw arm64
}
find_swift_lib() {
    name="$1"
    for dir in "$SWIFT_ORG_RUNTIME_DIR" "$SWIFT_LIB_DIR" "$SWIFT_LIB_DIR_BACKDEPLOY"; do
        if [ -f "$dir/$name" ]; then
            if has_arm64 "$dir/$name"; then
                echo "$dir/$name"
                return 0
            else
                echo "note: skipping $dir/$name (no arm64 slice: $(lipo -archs "$dir/$name" 2>/dev/null))" >&2
            fi
        fi
    done
    while IFS= read -r found; do
        [ -n "$found" ] || continue
        if has_arm64 "$found"; then
            echo "$found"
            return 0
        else
            echo "note: skipping $found (no arm64 slice)" >&2
        fi
    done <<EOF
$(find "$TOOLCHAIN_DIR" -path '*macosx*' -name "$name" -print 2>/dev/null)
EOF
    if [ -f "/usr/lib/swift/$name" ] && has_arm64 "/usr/lib/swift/$name"; then
        echo "/usr/lib/swift/$name"
        return 0
    fi
    return 1
}
copy_swift_lib() {
    name="$1"
    if [ ! -f "$APP/Contents/Frameworks/$name" ]; then
        src="$(find_swift_lib "$name")" || {
            # Run #17: a referenced Swift runtime library that the
            # toolchain no longer ships (libswiftCoreMIDI) cannot be
            # bundled — skip it and leave its /usr/lib/swift/
            # reference as-is; macOS 13 still provides it there.
            if ! grep -qx "$name" "$SWIFT_SKIP_TMP" 2>/dev/null; then
                echo "$name" >> "$SWIFT_SKIP_TMP"
                echo "warning: Swift runtime $name not shipped in the Xcode toolchain or the system runtime; leaving its /usr/lib/swift/ reference as-is" >&2
            fi
            return 0
        }
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
SWIFT_SKIP_TMP="/tmp/macplayer-swift-skip.$$"
: > "$SWIFT_SKIP_TMP"
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
rm -f "$SWIFT_DEPS_TMP" "$SWIFT_SKIP_TMP"
# Rewrite every /usr/lib/swift/ reference in the executable and all
# bundled dylibs (including the Swift dylibs themselves, which
# reference each other by absolute path) to @rpath/<basename> — but
# only for libraries actually bundled (run #17: a reference to a
# library the toolchain no longer ships, e.g. libswiftCoreMIDI,
# must keep pointing at /usr/lib/swift/, where macOS 13 still
# provides it).
for binary in "$APP/Contents/MacOS/MacPlayer" "$APP"/Contents/Frameworks/*.dylib; do
    [ -e "$binary" ] || continue
    otool -L "$binary" 2>/dev/null | awk '{print $1}' | grep '^/usr/lib/swift/.*\.dylib$' | while read -r dep; do
        base="$(basename "$dep")"
        if [ -f "$APP/Contents/Frameworks/$base" ]; then
            install_name_tool -change "$dep" "@rpath/$base" "$binary" 2>/dev/null || true
        fi
    done
done

# Fix LC_RPATH (v1.0.5 crash): rewriting load commands to @rpath is not
# enough. The Swift compiler embeds its own RPATHs at link time — the
# executable carries ['/usr/lib/swift',
# '@executable_path/../Frameworks'], libmpv.2.dylib carries the Xcode
# toolchain swift/macosx dir and '/usr/lib/swift' — and dyld resolves
# @rpath in RPATH order, so it found the macOS 13 system Swift 5.9
# libswiftCore in /usr/lib/swift first and never looked in the app's
# Frameworks, where the bundled Swift 6.2 runtime sits. The bundled
# runtime was therefore never used and the launch died with the same
# missing-symbol error as v1.0.4. Delete every RPATH that points
# outside the app; a binary that relied on RPATHs gets the Frameworks
# RPATH so its own @rpath references still resolve.
for binary in "$APP/Contents/MacOS/MacPlayer" "$APP"/Contents/Frameworks/*.dylib; do
    [ -e "$binary" ] || continue
    removed=""
    for rp in $(otool -l "$binary" 2>/dev/null | awk '/LC_RPATH/{p=1} p && /path/{print $2; p=0}' || true); do
        case "$rp" in
            @executable_path/../Frameworks|@loader_path|@loader_path/../Frameworks) ;;
            *)
                echo "removing RPATH $rp from $(basename "$binary")"
                install_name_tool -delete_rpath "$rp" "$binary" 2>/dev/null || true
                removed=1
                ;;
        esac
    done
    if [ -n "$removed" ]; then
        if ! otool -l "$binary" 2>/dev/null | awk '/LC_RPATH/{p=1} p && /path/{print $2; p=0}' | grep -qx '@executable_path/../Frameworks'; then
            install_name_tool -add_rpath "@executable_path/../Frameworks" "$binary" 2>/dev/null || true
        fi
    fi
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
# system Swift runtime for a library that IS bundled (v1.0.4 crash:
# libmpv needs a Swift 6.2 symbol missing from macOS 13's
# libswiftCore — the runtime must be bundled, so a reference to a
# bundled library via the system path means the @rpath rewrite
# missed it). A reference to a library the toolchain no longer ships
# (run #17: libswiftCoreMIDI) is allowed to stay on the system path.
# Fail loudly in CI instead of shipping an app that dies at launch.
for f in "$APP/Contents/MacOS/MacPlayer" "$APP"/Contents/Frameworks/*.dylib; do
    [ -e "$f" ] || continue
    if otool -L "$f" | grep -q '/usr/lib/libhvf\.dylib'; then
        echo "error: $f links /usr/lib/libhvf.dylib (macOS 26-only)" >&2
        exit 1
    fi
    SWIFT_GUARD_FAIL=""
    for dep in $(otool -L "$f" 2>/dev/null | awk '{print $1}' | grep '^/usr/lib/swift/.*\.dylib$' || true); do
        base="$(basename "$dep")"
        if [ -f "$APP/Contents/Frameworks/$base" ]; then
            echo "error: $f still links the system Swift runtime ($dep) although $base is bundled" >&2
            SWIFT_GUARD_FAIL=1
        else
            echo "note: $f links system Swift runtime $dep (not shipped in the Xcode 26.6 toolchain; resolves from the macOS 13 system runtime)"
        fi
    done
    [ -n "$SWIFT_GUARD_FAIL" ] && exit 1
done
# Guard: no bundled binary may carry an LC_RPATH pointing outside the
# app (v1.0.5 crash: the Swift compiler embedded /usr/lib/swift and the
# toolchain path as RPATHs in the executable and libmpv, so dyld
# resolved @rpath/libswiftCore.dylib to the macOS 13 system Swift 5.9
# runtime instead of the bundled one). The executable must keep
# @executable_path/../Frameworks so @rpath resolves inside the app.
for f in "$APP/Contents/MacOS/MacPlayer" "$APP"/Contents/Frameworks/*.dylib; do
    [ -e "$f" ] || continue
    bad="$(otool -l "$f" 2>/dev/null | awk '/LC_RPATH/{p=1} p && /path/{print $2; p=0}' | grep -E '/usr/lib/swift|/Applications/|/Users/|/opt/homebrew/' || true)"
    if [ -n "$bad" ]; then
        echo "error: $f has RPATH outside the app: $bad" >&2
        exit 1
    fi
done
if ! otool -l "$APP/Contents/MacOS/MacPlayer" | awk '/LC_RPATH/{p=1} p && /path/{print $2; p=0}' | grep -qx '@executable_path/../Frameworks'; then
    echo "error: MacPlayer executable lacks @executable_path/../Frameworks RPATH" >&2
    exit 1
fi
# Guard: every bundled dylib must contain an arm64 slice (v1.0.6
# crash: the Xcode 26.6 back-deploy Swift runtime libs are thin
# x86_64-only, and dyld refuses them on Apple Silicon with
# "incompatible architecture (have 'x86_64', need 'arm64')"). Fail
# loudly in CI instead of shipping an app that dies at launch.
for f in "$APP"/Contents/Frameworks/*.dylib; do
    [ -e "$f" ] || continue
    if ! lipo -archs "$f" 2>/dev/null | grep -qw arm64; then
        echo "error: $f has no arm64 slice: $(lipo -archs "$f" 2>/dev/null)" >&2
        exit 1
    fi
done
# Guard: libswiftCore must actually be bundled (v1.0.4 crash: the
# macOS 13 system Swift 5.9 runtime lacks a Swift 6.2 symbol libmpv
# needs, so a missing bundle would silently fall back to it and die
# at launch with "Symbol not found" instead of failing here).
if ! [ -f "$APP/Contents/Frameworks/libswiftCore.dylib" ]; then
    echo "error: libswiftCore.dylib was not bundled" >&2
    exit 1
fi
# Guard: every bundled binary must declare minimum macOS 13.0 (v1.0.7
# crash: Homebrew's libplacebo bottle declared minos 26.0 and
# referenced a libc++ symbol added in macOS 14, so the app died at
# launch on 13.7.8 with "Symbol not found"; the same applied to the
# other bottles). A binary built for a newer macOS can still load
# today if it happens not to reference a newer symbol, then die on
# the next one — so fail loudly in CI instead of shipping it.
echo "--- bundled binaries: minimum macOS ---"
for f in "$APP/Contents/MacOS/MacPlayer" "$APP"/Contents/Frameworks/*.dylib; do
    [ -e "$f" ] || continue
    minos="$(otool -l "$f" | awk '/LC_BUILD_VERSION/{p=1} p&&/minos/{print $2; exit} /LC_VERSION_MIN_MACOSX/{q=1} q&&/version/{print $2; exit}')"
    echo "$(basename "$f"): minos ${minos:-unknown}"
    major="${minos%%.*}"
    case "$major" in
        ''|*[!0-9]*)
            echo "error: $(basename "$f") declares no minimum macOS" >&2
            exit 1
            ;;
        *)
            if [ "$major" -gt 13 ]; then
                echo "error: $(basename "$f") requires macOS $minos (> 13.0) — build it from source with -mmacosx-version-min=13.0" >&2
                exit 1
            fi
            ;;
    esac
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
