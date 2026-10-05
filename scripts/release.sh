#!/bin/bash
# Builds a distributable SimpleToken.zip signed with a Developer ID certificate and, when credentials are
# given, notarized and stapled. Used locally and by .github/workflows/release.yml (see docs/RELEASING.md).
#
#   scripts/release.sh                                   # sign and zip (not notarized)
#   NOTARY_PROFILE=SimpleToken scripts/release.sh        # notarize with a notarytool keychain profile
#   NOTARY_KEY=key.p8 NOTARY_KEY_ID=… NOTARY_ISSUER=… scripts/release.sh   # with an App Store Connect API key
#
# Environment:
#   SIGN_IDENTITY         codesign identity (default: "Developer ID Application")
#   SIGN_KEYCHAIN         keychain holding that identity (default: the keychain search list)
#   NOTARY_PROFILE        a notarytool keychain profile, created once with
#                         `xcrun notarytool store-credentials <name> --apple-id <id> --team-id <team>`
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER
#                         an App Store Connect API key: the .p8 file, its key id and the issuer id
#   REQUIRE_NOTARIZATION  1: fail rather than produce a zip that is not notarized
#
# Output: dist/SimpleToken-<version>.zip and dist/SimpleToken-<version>.zip.sha256.
# Nothing secret is printed: credentials only reach codesign and notarytool.
set -euo pipefail

cd "$(dirname "$0")/.."
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
VERSION=$(sed -n 's/.*CFBundleShortVersionString: "\(.*\)"/\1/p' project.yml)
BUILD_DIR=build/release
APP="$BUILD_DIR/Build/Products/Release/SimpleToken.app"
DIST=dist
NAME="SimpleToken-$VERSION.zip"
ZIP="$DIST/$NAME"

if [ -n "${NOTARY_KEY:-}" ]; then
  : "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required with NOTARY_KEY}" "${NOTARY_ISSUER:?NOTARY_ISSUER is required with NOTARY_KEY}"
  NOTARIZE=key
elif [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARIZE=profile
elif [ "${REQUIRE_NOTARIZATION:-}" = 1 ]; then
  echo "error: notarization is required but no credentials were given (NOTARY_KEY… or NOTARY_PROFILE)" >&2
  exit 1
else
  NOTARIZE=
fi

sign() {
  if [ -n "${SIGN_KEYCHAIN:-}" ]; then
    codesign --force --timestamp --keychain "$SIGN_KEYCHAIN" --sign "$IDENTITY" "$@"
  else
    codesign --force --timestamp --sign "$IDENTITY" "$@"
  fi
}

notary() {
  if [ "$NOTARIZE" = key ]; then
    xcrun notarytool "$@" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"
  else
    xcrun notarytool "$@" --keychain-profile "$NOTARY_PROFILE"
  fi
}

echo "==> Building SimpleToken $VERSION"
rm -rf "$APP"
xcodegen generate >/dev/null
xcodebuild -project SimpleToken.xcodeproj -scheme SimpleToken -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$BUILD_DIR" \
  ARCHS=arm64 CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  build | grep -E "error:|BUILD" || true
[ -d "$APP" ] || { echo "error: build failed" >&2; exit 1; }

echo "==> Stripping debug symbols"
# The debug map in an unstripped binary lists the object files by their absolute build path
find "$APP/Contents/MacOS" -type f -exec codesign --remove-signature {} \; -exec xcrun strip -S {} \;

echo "==> Checking the app for build-machine paths"
# Our own code must not carry source or build paths (#filePath, debug maps); the bundled tokscale is third-party.
leaks=$(find "$APP/Contents" -type f -not -path "*/Resources/tokscale/*" -exec /usr/bin/grep -l -a -E "/Users/[^/]+/|/home/[^/]+/" {} + || true)
if [ -n "$leaks" ]; then
  echo "error: these files contain paths from the build machine:" >&2
  echo "$leaks" >&2
  exit 1
fi

echo "==> Signing with $IDENTITY (hardened runtime)"
# The build is signed ad-hoc; re-sign inside out: loose Mach-O files, nested bundles, then the app.
find "$APP/Contents/Resources" -type f | while read -r f; do
  if file "$f" | grep -q "Mach-O"; then
    sign --options runtime "$f"
  fi
done
find "$APP/Contents/Resources" -maxdepth 1 -name "*.bundle" | while read -r b; do
  sign "$b"
done
sign --options runtime "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

mkdir -p "$DIST"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "$NOTARIZE" ]; then
  echo "==> Notarizing (this can take a few minutes)"
  result=$(notary submit "$ZIP" --wait --output-format json)
  status=$(printf '%s' "$result" | plutil -extract status raw -o - - 2>/dev/null || true)
  if [ "$status" != "Accepted" ]; then
    echo "error: notarization finished with status '${status:-unknown}'" >&2
    id=$(printf '%s' "$result" | plutil -extract id raw -o - - 2>/dev/null || true)
    [ -n "$id" ] && notary log "$id" >&2 || true
    exit 1
  fi
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  spctl --assess --type execute --verbose "$APP"
else
  echo "==> Skipping notarization (set NOTARY_PROFILE or NOTARY_KEY to notarize)"
fi

(cd "$DIST" && shasum -a 256 "$NAME" > "$NAME.sha256" && cat "$NAME.sha256")
echo "==> $ZIP"
