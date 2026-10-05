#!/bin/bash
# Stores the signing and notarization credentials as secrets of the GitHub environment "release", which only the
# release workflow can read. Run it yourself in Terminal. Values go from the files and the hidden prompt straight
# to `gh secret set` on stdin: nothing is printed, written to disk or put on a command line.
#
#   scripts/set-release-secrets.sh <DeveloperID.p12> <AuthKey_XXXXXXXXXX.p8> <key id> <issuer id>
#
# See docs/RELEASING.md for how to export the .p12 and create the App Store Connect API key.
set -euo pipefail

p12=${1:?usage: set-release-secrets.sh <DeveloperID.p12> <AuthKey.p8> <key id> <issuer id>}
p8=${2:?App Store Connect API key (.p8) required}
key_id=${3:?key id required}
issuer=${4:?issuer id required}
[ -f "$p12" ] || { echo "error: $p12 not found" >&2; exit 1; }
[ -f "$p8" ] || { echo "error: $p8 not found" >&2; exit 1; }

export GH_HOST=github.com
cd "$(dirname "$0")/.."
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
gh api "repos/$repo/environments/release" --silent || { echo "error: the release environment does not exist yet" >&2; exit 1; }

read -r -s -p "Password of $(basename "$p12"): " p12_password
echo
if ! P12_PASSWORD="$p12_password" openssl pkcs12 -in "$p12" -passin env:P12_PASSWORD -noout 2>/dev/null; then
  echo "note: openssl could not open the .p12 (wrong password, or a format it does not read); storing it anyway" >&2
fi

set_secret() { gh secret set "$1" --env release --repo "$repo"; }
base64 -i "$p12" | set_secret DEVELOPER_ID_P12_BASE64
printf '%s' "$p12_password" | set_secret DEVELOPER_ID_P12_PASSWORD
base64 -i "$p8" | set_secret NOTARY_KEY_BASE64
printf '%s' "$key_id" | set_secret NOTARY_KEY_ID
printf '%s' "$issuer" | set_secret NOTARY_ISSUER_ID
unset p12_password

echo "Stored 5 secrets in the release environment of $repo."
echo "You can now delete the exported .p12 (rm -P \"$p12\"); keep the .p8 somewhere safe, Apple lets you download it only once."
