#!/bin/bash
# Builds "PDF Ream.app" next to this script. Needs only Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

APP="PDF Ream.app"
BUILD=build
mkdir -p "$BUILD"

echo "→ compiling"
ARCHS=""
for arch in arm64 x86_64; do
    if swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos13.0" \
        -o "$BUILD/PDFReam-$arch" Sources/*.swift 2>"$BUILD/build-$arch.log"; then
        ARCHS="$ARCHS $BUILD/PDFReam-$arch"
    else
        echo "  skipped architecture $arch (details: $BUILD/build-$arch.log)"
    fi
done
[ -n "$ARCHS" ] || { echo "could not build any architecture"; cat "$BUILD"/build-*.log; exit 1; }
# shellcheck disable=SC2086
lipo -create -output "$BUILD/PDFReam" $ARCHS
case " $(lipo -archs "$BUILD/PDFReam") " in
    *arm64*x86_64*|*x86_64*arm64*) ;;
    *) echo "  WARNING: single-architecture build — $(lipo -archs "$BUILD/PDFReam")" ;;
esac

echo "→ icon"
swiftc -O -o "$BUILD/make_icon" Tools/make_icon.swift
"$BUILD/make_icon" "$BUILD/AppIcon.iconset" >/dev/null
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"

echo "→ assembling the bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/PDFReam" "$APP/Contents/MacOS/PDFReam"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$APP" || { echo "codesign failed"; exit 1; }

echo "→ test tools"
swiftc -O -swift-version 5 -parse-as-library -o "$BUILD/pdfream-cli" Sources/PDFEngine.swift Tools/cli.swift
swiftc -O -swift-version 5 -o "$BUILD/make_fixtures" Tools/make_fixtures.swift
# Both harnesses declare their own @main, so PDFReamApp.swift is left out of the file list.
swiftc -O -swift-version 5 -parse-as-library -DUITEST -o "$BUILD/uitest" \
    Sources/PDFEngine.swift Sources/AppModel.swift Sources/ContentView.swift Sources/AppDelegate.swift Tools/uitest.swift
swiftc -O -swift-version 5 -parse-as-library -o "$BUILD/snapshot" \
    Sources/PDFEngine.swift Sources/AppModel.swift Sources/ContentView.swift Sources/AppDelegate.swift Tools/snapshot.swift

echo "done: $(pwd)/$APP  ($(lipo -archs "$APP/Contents/MacOS/PDFReam"))"
