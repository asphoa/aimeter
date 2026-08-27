#!/bin/bash
# Packages dist/AIMeter.app into a drag-to-Applications disk image.
#
# The app is signed with a local certificate, not an Apple Developer ID, and is
# not notarised — Gatekeeper will refuse to open it on someone else's Mac until
# they clear the quarantine flag. The release notes say how; there is no way to
# fix it from this side without a paid Developer ID and notarisation.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(cat VERSION)}"
APP="dist/AIMeter.app"
[ -d "$APP" ] || { echo "build it first: ./build.sh"; exit 1; }

# This script packages what is already in dist/ — it does not build. Bumping
# VERSION after the last ./build.sh therefore used to produce a disk image
# named for the new version and containing the old binary, with nothing to see
# from the outside: a release that is wrong in the one way a version number
# exists to prevent. Compare the two and refuse.
BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
         "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
if [ "$BUILT" != "$VERSION" ]; then
  echo "✗ $APP was built as $BUILT, but you are packaging $VERSION."
  echo "  Run ./build.sh first — this script only packages, it never builds."
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

OUT="dist/AIMeter-${VERSION}.dmg"
rm -f "$OUT"
hdiutil create -volname "AIMeter" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
echo "✅ $PWD/$OUT  ($(du -h "$OUT" | cut -f1))"
