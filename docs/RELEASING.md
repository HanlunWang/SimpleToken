# Releasing

Pushing a tag `vX.Y.Z` runs [`.github/workflows/release.yml`](../.github/workflows/release.yml) on a GitHub-hosted Mac: unit tests, a Release build, Developer ID signing with the hardened runtime, notarization, stapling, and a GitHub Release with `SimpleToken-X.Y.Z.zip` and its SHA-256. [`ci.yml`](../.github/workflows/ci.yml) builds and tests every push to `main` and every pull request, without any secrets.

## One-time setup

1. **Export the signing identity.** In Keychain Access, under *login → My Certificates*, right-click *Developer ID Application: …* and choose *Export*. Save it as a `.p12` with a strong password.
2. **Create an App Store Connect API key** for notarization: App Store Connect → *Users and Access* → *Integrations* → *App Store Connect API* → *Team Keys* → *+*, with the *Developer* role. Download the `AuthKey_XXXXXXXXXX.p8` (Apple offers it only once) and note the *Key ID* and the *Issuer ID*.
3. **Store them as secrets** of the `release` environment:

   ```bash
   scripts/set-release-secrets.sh ~/Desktop/DeveloperID.p12 ~/Downloads/AuthKey_XXXXXXXXXX.p8 <key id> <issuer id>
   ```

   It asks for the `.p12` password with hidden input and passes every value to `gh secret set` on stdin.
4. Delete the exported `.p12` (`rm -P …`). Keep the `.p8` somewhere safe.

To check that signing and notarization work before tagging, run the *Release* workflow by hand from `main` (Actions → Release → Run workflow). It does everything except publish.

Developer ID certificates expire. After renewing one, export it again and re-run step 3.

## Cutting a release

1. Set the version in `project.yml` (`CFBundleShortVersionString`, and raise `CFBundleVersion`).
2. Write the release notes in `docs/releases/X.Y.Z.md` (without one, GitHub generates notes from the commits).
3. Commit and push to `main`, then tag and push the tag:

   ```bash
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

   Push only that tag, not `--tags`. The workflow refuses a tag that does not match `project.yml`. Running it again for an existing release replaces the files.

## How the secrets are protected

- They are secrets of the `release` environment, which accepts runs only from `v*` tags and `main`. Pull requests, including those from forks, never see them.
- The workflow uses a single third-party action, `actions/checkout`, pinned to a commit, with its credentials not persisted. Everything else is shell scripts in this repository.
- The certificate goes into a temporary keychain with a random password, together with Apple's Developer ID intermediates (checked against pinned fingerprints). The keychain and the decoded key files live in the runner's temp directory and are removed at the end, even when a step fails. No step prints a secret, and GitHub masks them in logs as well.
- `scripts/release.sh` strips debug maps from the app and refuses to sign it if the app's own files contain paths from the build machine.

## Releasing locally

`scripts/release.sh` also runs on your Mac with the Developer ID identity in your login keychain: set `NOTARY_PROFILE` (a `notarytool store-credentials` profile) or `NOTARY_KEY` / `NOTARY_KEY_ID` / `NOTARY_ISSUER` to notarize. The zip lands in `dist/`.
