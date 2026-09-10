#!/bin/bash
# Packs "PDF Ream.app" into a zip for a GitHub release. Usage: Tools/package.sh
# Commit first: the zip should match the tag it is released under. ALLOW_DIRTY=1 skips that check.
#
# Builds from the current sources, refuses a single-architecture build, copies the app out of
# the checkout (a synced folder such as an iCloud Desktop tags the bundle with Finder metadata
# that fails strict signature checks), strips extended attributes, verifies the signature
# strictly, zips it without any Mac metadata (no __MACOSX or ._ entries: the signature does not
# depend on them), then checks the zip by unpacking it with both ditto and unzip.
# Writes dist/PDF-Ream-<version>.zip and a .sha256 next to it.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
APP="PDF Ream.app"

if [ -z "${ALLOW_DIRTY:-}" ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    echo "uncommitted changes: commit first, so the zip matches the release tag (or set ALLOW_DIRTY=1)"
    exit 1
fi

./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
ARCHS=$(lipo -archs "$APP/Contents/MacOS/PDFReam")
case " $ARCHS " in
    *arm64*x86_64*|*x86_64*arm64*) ;;
    *) echo "refusing to package a single-architecture build ($ARCHS)"; exit 1 ;;
esac

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/pdfream-release.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
echo "→ staging a clean copy"
ditto "$APP" "$STAGE/$APP"
xattr -cr "$STAGE/$APP"
codesign --verify --deep --strict "$STAGE/$APP"

echo "→ zipping"
mkdir -p dist
NAME="PDF-Ream-$VERSION.zip"
rm -f "dist/$NAME" "dist/$NAME.sha256"
(cd "$STAGE" && ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ROOT/dist/$NAME")

echo "→ checking the zip"
mkdir "$STAGE/ditto" "$STAGE/unzip"
ditto -x -k "dist/$NAME" "$STAGE/ditto"
codesign --verify --deep --strict "$STAGE/ditto/$APP"
(cd "$STAGE/unzip" && unzip -q "$ROOT/dist/$NAME")
codesign --verify --deep --strict "$STAGE/unzip/$APP"
if unzip -Z1 "dist/$NAME" | grep -q -e '__MACOSX' -e '/\._'; then echo "the zip carries Mac metadata entries"; exit 1; fi
(cd dist && shasum -a 256 "$NAME" > "$NAME.sha256")

echo "done: dist/$NAME  ($ARCHS)"
cat "dist/$NAME.sha256"
echo "next: git tag v$VERSION && git push origin v$VERSION"
echo "      gh release create v$VERSION \"dist/$NAME\" \"dist/$NAME.sha256\" --title \"PDF Ream $VERSION\" --notes-file CHANGELOG.md"
