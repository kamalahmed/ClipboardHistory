#!/bin/bash
# Build, sign, notarize and staple a distributable ClipboardHistory.dmg.
#
# One-time prerequisites on the build Mac:
#   * A "Developer ID Application" certificate in the keychain
#     (Xcode → Settings → Accounts → Manage Certificates → +)
#   * Notary credentials stored in the keychain:
#       xcrun notarytool store-credentials ClipboardHistory \
#         --apple-id <your-apple-id> --team-id 33X88N4LQ3
#
# Then: ./scripts/release.sh
# Result: dist/ClipboardHistory.dmg — notarized, stapled, ready to upload
# to a GitHub release.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="Developer ID Application: Kamal Ahmed (33X88N4LQ3)"

echo "== Building Release…"
xcodebuild -scheme ClipboardHistory -configuration Release build

APP="$(xcodebuild -scheme ClipboardHistory -configuration Release -showBuildSettings \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2}')/ClipboardHistory.app"

echo "== Signing with Developer ID…"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"

echo "== Packaging DMG…"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
cp "packaging/README - Please read first.txt" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p dist
rm -f dist/ClipboardHistory.dmg
hdiutil create -volname "ClipboardHistory" -srcfolder "$STAGE" -ov -format UDZO \
  dist/ClipboardHistory.dmg
codesign --sign "$IDENTITY" --timestamp dist/ClipboardHistory.dmg

echo "== Notarizing (Apple usually takes 1–5 minutes)…"
xcrun notarytool submit dist/ClipboardHistory.dmg \
  --keychain-profile ClipboardHistory --wait

echo "== Stapling ticket…"
xcrun stapler staple dist/ClipboardHistory.dmg

echo "== Gatekeeper check…"
spctl -a -t open --context context:primary-signature -v dist/ClipboardHistory.dmg

echo "Done: dist/ClipboardHistory.dmg is notarized and ready to upload."
