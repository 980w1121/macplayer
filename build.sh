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
# One pass over the bundled dylibs: copy any Homebrew dylib they link to.
for bundled in "$APP"/Contents/Frameworks/*.dylib; do
    [ -e "$bundled" ] || continue
    otool -L "$bundled" 2>/dev/null | awk '{print $1}' | grep '^/opt/homebrew/lib/.*\.dylib$' | while read -r dep; do
        copy_dylib "$dep"
    done
done
# Rewrite @rpath references inside the bundled dylibs to the new location.
for bundled in "$APP"/Contents/Frameworks/*.dylib; do
    [ -e "$bundled" ] || continue
    otool -L "$bundled" 2>/dev/null | awk '{print $1}' | grep -E '^(@rpath|/opt/homebrew/lib|deps/lib)/' | while read -r dep; do
        base="$(basename "$dep")"
        install_name_tool -change "$dep" "@rpath/$base" "$bundled" 2>/dev/null || true
    done
done

# Unsigned on purpose (see README): no codesign step here.
echo "--- checks ---"
file "$APP/Contents/MacOS/MacPlayer"
lipo -info "$APP/Contents/MacOS/MacPlayer"
# Guard: the binary must declare minos 13.0, or macOS 13 refuses it.
# otool prints minos on the 3rd line after "cmd LC_BUILD_VERSION"
# (cmdsize, platform, minos), so -A3 is required — -A2 never saw
# the minos line and failed even when minos was correct (run #8).
otool -l "$APP/Contents/MacOS/MacPlayer" | grep -A3 LC_BUILD_VERSION | grep -q "minos 13.0" \
    || { echo "error: MacPlayer minos is not 13.0" >&2; otool -l "$APP/Contents/MacOS/MacPlayer" | grep -A3 LC_BUILD_VERSION >&2; exit 1; }
ls -lh "$APP/Contents/Frameworks/" | head -30
echo "Built: $APP"
