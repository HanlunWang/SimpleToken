#!/bin/bash
# A throwaway keychain holding the Developer ID identity, for signing on a build machine (CI).
#
#   P12_PASSWORD=… scripts/signing-keychain.sh create <keychain> <identity.p12>
#   scripts/signing-keychain.sh delete <keychain>
#
# create makes the keychain with a random password that never leaves this process, imports the identity and
# Apple's Developer ID intermediates (pinned by fingerprint), lets codesign use the key without a prompt and,
# unless KEYCHAIN_SEARCH=0, adds the keychain to the user's search list so codesign can build the chain.
# Nothing secret is printed.
set -euo pipefail

command=${1:?usage: signing-keychain.sh create|delete <keychain> [identity.p12]}
keychain=${2:?keychain path required}

# Developer ID Certification Authority (G1, until 2027-02-01) and its G2 successor
intermediates=(
  "https://www.apple.com/certificateauthority/DeveloperIDCA.cer 7afc9d01a62f03a2de9637936d4afe68090d2de18d03f29c88cfb0b1ba63587f"
  "https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer f16cd3c54c7f83cea4bf1a3e6a0819c8aaa8e4a1528fd144715f350643d2df3a"
)

case "$command" in
create)
  p12=${3:?identity .p12 required}
  : "${P12_PASSWORD:?P12_PASSWORD must be set}"
  password=$(openssl rand -hex 24)
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::add-mask::$password"
  security create-keychain -p "$password" "$keychain"
  security set-keychain-settings -lut 21600 "$keychain"
  security unlock-keychain -p "$password" "$keychain"
  security import "$p12" -k "$keychain" -P "$P12_PASSWORD" -T /usr/bin/codesign -f pkcs12 >/dev/null
  tmp=$(mktemp -d)
  for entry in "${intermediates[@]}"; do
    url=${entry% *}
    fingerprint=${entry#* }
    curl -fsSL "$url" -o "$tmp/ca.cer"
    if [ "$(shasum -a 256 "$tmp/ca.cer" | cut -d' ' -f1)" != "$fingerprint" ]; then
      echo "error: unexpected certificate from $url" >&2
      rm -rf "$tmp"
      exit 1
    fi
    security import "$tmp/ca.cer" -k "$keychain" >/dev/null 2>&1 || true
  done
  rm -rf "$tmp"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
  if [ "${KEYCHAIN_SEARCH:-1}" != 0 ]; then
    current=()
    while IFS= read -r line; do
      line=${line#"${line%%[![:space:]]*}"}
      line=${line//\"/}
      [ -n "$line" ] && current+=("$line")
    done < <(security list-keychains -d user)
    security list-keychains -d user -s "$keychain" ${current[@]+"${current[@]}"}
  fi
  identities=$(security find-identity -v -p codesigning "$keychain" | grep -c "Developer ID Application" || true)
  echo "Signing keychain ready ($identities Developer ID Application identity)"
  [ "$identities" -ge 1 ] || { echo "error: no Developer ID Application identity in the .p12" >&2; exit 1; }
  ;;
delete)
  security delete-keychain "$keychain" 2>/dev/null || true
  ;;
*)
  echo "usage: signing-keychain.sh create|delete <keychain> [identity.p12]" >&2
  exit 2
  ;;
esac
