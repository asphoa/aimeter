#!/bin/bash
# Builds AIMeter.app. Uses swiftc directly rather than `swift build`: SwiftPM
# spawns its own sandbox-exec for manifest evaluation, which cannot nest inside
# the Claude Code sandbox.
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/AIMeter.app"
BUNDLE_ID="${AIMETER_BUNDLE_ID:-com.example.aimeter}"
VERSION="$(cat VERSION)"
mkdir -p .build/{tmp,modcache}

echo "→ 編譯"
TMPDIR="$PWD/.build/tmp" swiftc -O -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  -module-cache-path "$PWD/.build/modcache" \
  -o .build/AIMeter \
  Sources/AIMeter/*.swift Sources/AIMeter/Providers/*.swift

echo "→ 圖示"
# Drawn by code like everything else here — no bundled art. Note: iconutil
# talks to an XPC service and fails inside a sandbox, which is one more reason
# this script must run outside one.
if [ ! -f .build/AppIcon.icns ] || [ tools/make_app_icon.swift -nt .build/AppIcon.icns ]; then
    TMPDIR="$PWD/.build/tmp" swiftc -O -swift-version 5 \
      -target arm64-apple-macosx14.0 \
      -module-cache-path "$PWD/.build/modcache" \
      -o .build/make_app_icon tools/make_app_icon.swift
    .build/make_app_icon .build/AppIcon.icns
fi

echo "→ 組 .app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/AIMeter "$APP/Contents/MacOS/AIMeter"
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AIMeter</string>
    <key>CFBundleDisplayName</key><string>AIMeter</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>AIMeter</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- menu bar only: no Dock icon, no Cmd-Tab entry -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# A stable signing identity is what makes the keychain's "Always Allow" grant
# survive a rebuild; an ad-hoc signature changes with every byte of the binary,
# so macOS treats each build as a different application and asks again.
# Note: signing with this deliberately untrusted certificate needs to reach the
# system trust daemon, which some sandboxes block — the symptom is codesign
# failing with CSSMERR_TP_NOT_TRUSTED while the compile itself succeeded. Run
# this script outside such a sandbox.
IDENTITY="AIMeter Local Signing"
# The certificate is untrusted by design, so it does not appear in
# `find-identity -p codesigning`; look for the certificate itself.
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    echo "→ signing with $IDENTITY"
    codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
    echo "→ signing ad-hoc (run tools/make_signing_cert.sh for a stable identity)"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --verbose=1 "$APP" 2>&1 | tail -2

echo "✅ $PWD/$APP"
