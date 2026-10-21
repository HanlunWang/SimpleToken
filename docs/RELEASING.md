# Releasing

Pushing a tag `vX.Y.Z` runs [`.github/workflows/release.yml`](../.github/workflows/release.yml) on a GitHub-hosted Mac. It runs the tests, then [`scripts/release.sh`](../scripts/release.sh), which has `mygo build` compile the app, sign it and its bundled tokscale with the Developer ID (hardened runtime, timestamp), notarize the disk image, staple the app and the image, and sign the update archive. The workflow then publishes a GitHub Release with:

- `SimpleToken-X.Y.Z.dmg` and its SHA-256, for people;
- `SimpleToken-X.Y.Z-darwin-arm64.tar.gz` and `update-darwin-arm64.json` (plus deltas from earlier versions), which installed apps read from `releases/latest/download/` to update themselves.

[`ci.yml`](../.github/workflows/ci.yml) tests and builds every push to `main` and `v2` and every pull request, without any secrets.

## One-time setup

1. **Export the signing identity.** In Keychain Access, under *login → My Certificates*, right-click *Developer ID Application: …* and choose *Export*. Save it as a `.p12` with a strong password.
2. **Create an App Store Connect API key** for notarization: App Store Connect → *Users and Access* → *Integrations* → *App Store Connect API* → *Team Keys* → *+*, with the *Developer* role. Download the `AuthKey_XXXXXXXXXX.p8` (Apple offers it only once) and note the *Key ID* and the *Issuer ID*.
3. **Store them as secrets** of the `release` environment:

   ```bash
   scripts/set-release-secrets.sh ~/Desktop/DeveloperID.p12 ~/Downloads/AuthKey_XXXXXXXXXX.p8 <key id> <issuer id>
   ```

   It asks for the `.p12` password with hidden input and passes every value to `gh secret set` on stdin.
4. **Create the update-signing key** (once, ever):

   ```bash
   scripts/set-update-key.sh
   ```

   It runs `mygo keygen`, stores the secret key as `MYGO_UPDATER_PRIVATE_KEY` in the `release` environment, and writes the public key into `mygo.json`. Save `mygo-update.key` in your password manager and delete the local copy as it tells you: installed apps accept only updates signed with this key, so losing it strands them and anyone holding it can ship code to every user. Commit the `mygo.json` change.
5. Delete the exported `.p12` (`rm -P …`). Keep the `.p8` somewhere safe.

To check signing and notarization before tagging, run the *Release* workflow by hand from `main` (Actions → Release → Run workflow). It does everything except publish.

Developer ID certificates expire. After renewing one, export it again and re-run step 3.

## Cutting a release

1. Set `version` in `mygo.json`.
2. Write the release notes in `docs/releases/X.Y.Z.md`. They become the GitHub release notes and the notes installed apps show for the update.
3. Commit and push to `main`, then tag and push the tag:

   ```bash
   git tag -m "SimpleToken X.Y.Z" vX.Y.Z
   git push origin vX.Y.Z
   ```

   Push only that tag, not `--tags`. The workflow refuses a tag that does not match `mygo.json`, and a tag build without the update key. Running it again for an existing release replaces the files.

## How the secrets are protected

- They are secrets of the `release` environment, which accepts runs only from `v*` tags and `main`. Pull requests, including those from forks, never see them.
- The workflow uses a single third-party action, `actions/checkout`, pinned to a commit, with its credentials not persisted. Everything else is shell scripts in this repository and the Go toolchain.
- The certificate goes into a temporary keychain with a random password, together with Apple's Developer ID intermediates (checked against pinned fingerprints). The notary credentials become a notarytool profile in that keychain for the one run. The keychain and the decoded key files live in the runner's temp directory and are removed at the end, even when a step fails. No step prints a secret, and GitHub masks them in logs as well.
- `scripts/release.sh` gives `mygo build` the identity and notary profile through a temporary edit of `mygo.json`, restored on exit, and refuses to publish an app whose own files contain paths from the build machine.

## Releasing locally

`scripts/release.sh` also runs on your Mac with the Developer ID identity in your login keychain: set `NOTARY_PROFILE` (a `notarytool store-credentials` profile) or `NOTARY_KEY` / `NOTARY_KEY_ID` / `NOTARY_ISSUER` to notarize, and `MYGO_UPDATER_PRIVATE_KEY` to sign the update archive. The files land in `dist/`.

## Upgrading from 0.1.x

0.1.x (the Swift app) has no updater: its users download the first Go release by hand. It keeps the bundle id `dev.hanlun.simpletoken` and the data directory, and imports the 0.1.x settings from UserDefaults on first launch.
