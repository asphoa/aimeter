#!/bin/bash
# Packages dist/AIMeter.app into a drag-to-Applications disk image.
#
# The app is signed with a local certificate, not an Apple Developer ID, and is
# not notarised — Gatekeeper will refuse to open it on someone else's Mac until
# they clear the quarantine flag. The release notes say how; there is no way to
# fix it from this side without a paid Developer ID and notarisation.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: make_dmg.sh <version>}"
APP="dist/AIMeter.app"
[ -d "$APP" ] || { echo "build it first: ./build.sh"; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

OUT="dist/AIMeter-${VERSION}.dmg"
rm -f "$OUT"
hdiutil create -volname "AIMeter" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
echo "✅ $PWD/$OUT  ($(du -h "$OUT" | cut -f1))"
