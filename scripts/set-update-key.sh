#!/bin/bash
# Creates the Ed25519 key pair that signs SimpleToken's automatic updates, stores the secret key as a secret of
# the GitHub environment "release" (stdin only: never printed or put on a command line), and writes the public
# key into mygo.json. Run it yourself in Terminal, once.
#
#   scripts/set-update-key.sh
#
# Afterwards: save mygo-update.key in your password manager (installed apps accept only updates signed with
# it; losing it strands them), then delete the local copy as the script tells you. Commit the mygo.json change.
set -euo pipefail

export GH_HOST=github.com
cd "$(dirname "$0")/.."
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
gh api "repos/$repo/environments/release" --silent || { echo "error: the release environment does not exist yet" >&2; exit 1; }
if plutil -extract updates.publicKey raw -o - mygo.json >/dev/null 2>&1; then
  echo "error: mygo.json already has updates.publicKey; replacing the key would strand installed apps" >&2
  exit 1
fi

dir=$(mktemp -d "${TMPDIR:-/tmp}/simpletoken-update-key.XXXXXX")
chmod 700 "$dir"
go tool mygo keygen -o "$dir" >/dev/null
[ -f "$dir/mygo-update.key" ] && [ -f "$dir/mygo-update.pub" ] || { echo "error: mygo keygen wrote no key pair" >&2; exit 1; }

gh secret set MYGO_UPDATER_PRIVATE_KEY --env release --repo "$repo" < "$dir/mygo-update.key"
python3 - "$dir/mygo-update.pub" "$repo" <<'EOF'
import json, sys
pub = open(sys.argv[1]).read().strip()
c = json.load(open("mygo.json"))
c["updates"] = {"publicKey": pub, "github": sys.argv[2]}
json.dump(c, open("mygo.json", "w"), indent=2)
open("mygo.json", "a").write("\n")
EOF

echo "Stored MYGO_UPDATER_PRIVATE_KEY in the release environment of $repo and wrote the public key to mygo.json."
echo "Now save $dir/mygo-update.key in your password manager, then remove the folder:"
echo "  rm -P \"$dir/mygo-update.key\" && rm -r \"$dir\""
