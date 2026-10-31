# GitHub updates

Settings > Updates and the Sunno menu run a manual Sparkle check. The feed is the `appcast.xml`
asset on the latest stable GitHub release in `desigrit/sunno-macos`. No automatic checks, downloads,
system-profile submission, audio or transcript uploads are enabled.

Both the appcast and the ZIP require Ed25519 signatures. The verification key is public and
committed in `config/Updater.xcconfig`; the private key stays in the release Mac's login Keychain
under account `com.desigrit.sunno.sparkle`. Keep a secure backup of that Keychain. Do not generate
a replacement key for an established release: installed clients trust the original public key.

## First release setup

1. Unlock the login Keychain locally on the release Mac.
2. Run `bash scripts/configure-updater-key.sh` once. Commit the resulting public key.
3. Increment `SUNNO_RELEASE_VERSION`, `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
   `project.yml` for each release. Release 1.0.92.0 uses Apple's three-part bundle version
   1.0.92 and build 5. Settings, the ZIP and the GitHub tag use the shared release number.
   The build number is monotonic and identical in the command-line and Xcode builds.
4. Run `bash scripts/package-app.sh`. It pins and verifies Sparkle 2.10.1, embeds and signs its
   helpers, verifies the app signature, and produces the ZIP and signed appcast in `dist/`.
5. Test the app, commit the release sources, push the version tag, then run
   `bash scripts/publish-release.sh`. Both assets upload to a draft before it becomes public.

The first version with this updater needs a manual installation. Later versions can install
through the button. The feed becomes available when the first signed release is published.
Self-signed builds still require the usual macOS first-install approval; Sparkle signing does
not replace Apple Developer ID signing or notarisation.

## Runtime behavior

Sparkle is created only on the first requested check. Its native window handles update progress,
cancellation, errors and relaunch. Settings also reports status and provides a GitHub releases
link. A check cannot begin while recording or saving. If recording starts during a download,
installation waits until recording and saving finish before restarting the app.

The release helper reads metadata from the ZIP itself and rejects wrong bundle identities,
versions, feed URLs and verification keys. Published version assets are never overwritten.
If publishing stops after uploading a draft, inspect that draft and complete it deliberately.

## Checks

`python3 tests/test_appcast.py` checks archive identity, key, feed URL, signature shape, version,
compatibility and filename consistency. `python3 tests/test_app_updater.py` runs native macOS
checks for recording deferral, one-time relaunch, compatibility messages, cancellation and
retry. It does not start an updater session or contact GitHub. Packaging additionally verifies
the actual archive and appcast signatures with Sparkle's release tools.
