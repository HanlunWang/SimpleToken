#!/bin/bash
# Builds, signs and notarizes SimpleToken (the Go app on mygo) into dist/. Used locally and by
# .github/workflows/release.yml (see docs/RELEASING.md).
#
#   scripts/release.sh                                   # Developer ID signature, not notarized
#   NOTARY_PROFILE=SimpleToken scripts/release.sh        # notarize with a notarytool keychain profile
#   NOTARY_KEY=key.p8 NOTARY_KEY_ID=… NOTARY_ISSUER=… scripts/release.sh   # with an App Store Connect API key
#
# Environment:
#   SIGN_IDENTITY              codesign identity (default: the only "Developer ID Application" one found)
#   SIGN_KEYCHAIN              keychain holding it (default: the search list)
#   NOTARY_PROFILE             a notarytool keychain profile
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER
#                              an App Store Connect API key: the .p8 file, its key id and the issuer id
#   MYGO_UPDATER_PRIVATE_KEY   the Ed25519 key that signs updates (contents of mygo-update.key); with it the
#                              build also writes the update archive and manifest that installed apps read
#   REQUIRE_NOTARIZATION=1     fail rather than produce an app that is not notarized
#   REQUIRE_UPDATES=1          fail rather than produce a release installed apps cannot update to
#
# mygo signs (inside out, hardened runtime, timestamp), notarizes the disk image, staples the app and the image,
# and signs the update archive. Its configuration gets the identity and notary profile for this run only:
# mygo.json is restored afterwards. Nothing secret is printed.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION=$(plutil -extract version raw -o - mygo.json)
OUT=build/release
PLATFORM_DIR="$OUT/darwin-arm64"
DIST=dist
PROFILE="simpletoken-notary-$$"

if [ -n "${NOTARY_KEY:-}" ]; then
  : "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required with NOTARY_KEY}" "${NOTARY_ISSUER:?NOTARY_ISSUER is required with NOTARY_KEY}"
  NOTARIZE=key
elif [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARIZE=profile
  PROFILE="$NOTARY_PROFILE"
elif [ "${REQUIRE_NOTARIZATION:-}" = 1 ]; then
  echo "error: notarization is required but no credentials were given (NOTARY_KEY… or NOTARY_PROFILE)" >&2
  exit 1
else
  NOTARIZE=
fi
if [ "${REQUIRE_UPDATES:-}" = 1 ]; then
  [ -n "${MYGO_UPDATER_PRIVATE_KEY:-}" ] || { echo "error: updates are required but MYGO_UPDATER_PRIVATE_KEY is not set" >&2; exit 1; }
  plutil -extract updates.publicKey raw -o - mygo.json >/dev/null 2>&1 || { echo "error: mygo.json has no updates.publicKey" >&2; exit 1; }
fi

# The identity: the one asked for, else the single Developer ID Application identity available.
if [ -z "${SIGN_IDENTITY:-}" ]; then
  ids=$(security find-identity -v -p codesigning ${SIGN_KEYCHAIN:+"$SIGN_KEYCHAIN"} | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | sort -u)
  [ "$(printf '%s\n' "$ids" | grep -c .)" = 1 ] || { echo "error: expected exactly one Developer ID Application identity; set SIGN_IDENTITY" >&2; exit 1; }
  SIGN_IDENTITY=$ids
fi

echo "==> Testing"
go vet ./...
go test ./internal/... ./gui/

# Release notes for the update manifest: this version's section, in the CHANGELOG shape mygo reads.
mkdir -p "$OUT"
notes="docs/releases/$VERSION.md"
changelog="$OUT/CHANGELOG.md"
{ echo "## $VERSION"; echo; if [ -f "$notes" ]; then cat "$notes"; else echo "SimpleToken $VERSION"; fi; } > "$changelog"

cp mygo.json "$OUT/mygo.json.orig"
restore() {
  cp "$OUT/mygo.json.orig" mygo.json
  if [ "$NOTARIZE" = key ]; then
    # The profile lives in the signing keychain (CI) or the login keychain; drop it either way.
    security delete-generic-password -s "com.apple.gke.notary.tool" -a "com.apple.gke.notary.tool.saved-creds.$PROFILE" ${SIGN_KEYCHAIN:+"$SIGN_KEYCHAIN"} >/dev/null 2>&1 || true
  fi
}
trap restore EXIT

if [ "$NOTARIZE" = key ]; then
  xcrun notarytool store-credentials "$PROFILE" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" \
    ${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"} >/dev/null
fi

# This run's configuration: identity, notary profile, changelog.
python3 - "$SIGN_IDENTITY" "$NOTARIZE" "$PROFILE" "${SIGN_KEYCHAIN:-}" "$changelog" <<'EOF'
import json, sys
identity, notarize, profile, keychain, changelog = sys.argv[1:]
c = json.load(open("mygo.json"))
mac = c.setdefault("macos", {})
mac["signingIdentity"] = identity
if notarize:
    mac["notarize"] = {"keychainProfile": profile}
    if keychain:
        mac["notarize"]["keychain"] = keychain
if "updates" in c:
    c["updates"]["changelog"] = changelog
json.dump(c, open("mygo.json", "w"), indent=2)
EOF

echo "==> Building SimpleToken $VERSION (signing as the Developer ID identity)"
rm -rf "$PLATFORM_DIR"
flags=(-o "$OUT")
[ -z "$NOTARIZE" ] && flags+=(-skip-notarize)
go tool mygo build "${flags[@]}"

APP="$PLATFORM_DIR/SimpleToken.app"
[ -d "$APP" ] || { echo "error: no app in $PLATFORM_DIR" >&2; exit 1; }

echo "==> Checking the app for build-machine paths"
# Our own code must not carry source or build paths; the bundled tokscale is third-party.
leaks=$(find "$APP/Contents" -type f -not -path "*/Resources/tokscale/*" -exec /usr/bin/grep -l -a -E "/Users/[^/]+/|/home/[^/]+/" {} + || true)
if [ -n "$leaks" ]; then
  echo "error: these files contain paths from the build machine:" >&2
  echo "$leaks" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=1 "$APP"
if [ -n "$NOTARIZE" ]; then
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose "$APP"
fi

echo "==> Collecting the release files"
mkdir -p "$DIST"
rm -f "$DIST"/SimpleToken-"$VERSION"* "$DIST"/update-darwin-arm64.json
for f in "$PLATFORM_DIR"/*.dmg "$PLATFORM_DIR"/*.tar.gz "$PLATFORM_DIR"/*.delta "$PLATFORM_DIR"/update-*.json; do
  [ -e "$f" ] && cp "$f" "$DIST/"
done
dmg=$(ls "$DIST"/*"$VERSION"*.dmg 2>/dev/null | head -1 || true)
[ -n "$dmg" ] || { echo "error: no disk image was built" >&2; exit 1; }
named="$DIST/SimpleToken-$VERSION.dmg"
[ "$dmg" = "$named" ] || mv "$dmg" "$named"
(cd "$DIST" && shasum -a 256 "SimpleToken-$VERSION.dmg" > "SimpleToken-$VERSION.dmg.sha256" && cat "SimpleToken-$VERSION.dmg.sha256")
ls -1 "$DIST"
