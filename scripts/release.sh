#!/bin/bash
# Builds a distributable SimpleToken.zip signed with a Developer ID certificate.
#
#   scripts/release.sh                      # sign and zip (not notarized)
#   NOTARY_PROFILE=SimpleToken scripts/release.sh   # also notarize and staple
#
# Environment:
#   SIGN_IDENTITY   codesign identity (default: "Developer ID Application")
#   NOTARY_PROFILE  a notarytool keychain profile, created once with
#                   `xcrun notarytool store-credentials <name> --apple-id <id> --team-id <team>`
#
# Output: dist/SimpleToken-<version>.zip and its SHA-256.
set -euo pipefail

cd "$(dirname "$0")/.."
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
VERSION=$(sed -n 's/.*CFBundleShortVersionString: "\(.*\)"/\1/p' project.yml)
BUILD_DIR=build/release
APP="$BUILD_DIR/Build/Products/Release/SimpleToken.app"
DIST=dist
ZIP="$DIST/SimpleToken-$VERSION.zip"

echo "==> Building SimpleToken $VERSION"
rm -rf "$APP"
xcodegen generate >/dev/null
xcodebuild -project SimpleToken.xcodeproj -scheme SimpleToken -configuration Release \
  -derivedDataPath "$BUILD_DIR" CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  build | grep -E "error:|BUILD" || true
[ -d "$APP" ] || { echo "build failed"; exit 1; }

echo "==> Signing with $IDENTITY (hardened runtime)"
# The build is signed ad-hoc; re-sign inside out: loose Mach-O files, nested bundles, then the app.
find "$APP/Contents/Resources" -type f | while read -r f; do
  if file "$f" | grep -q "Mach-O"; then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$f"
  fi
done
find "$APP/Contents/Resources" -maxdepth 1 -name "*.bundle" | while read -r b; do
  codesign --force --timestamp --sign "$IDENTITY" "$b"
done
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

mkdir -p "$DIST"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "==> Notarizing (this can take a few minutes)"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  spctl --assess --type execute --verbose "$APP"
else
  echo "==> Skipping notarization (set NOTARY_PROFILE to notarize)"
fi

shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
echo "==> $ZIP"
