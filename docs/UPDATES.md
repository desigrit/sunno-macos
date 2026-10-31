# GitHub updates

Settings > Updates and the Sunno menu run a manual Sparkle check. The feed is the `appcast.xml`
asset on the latest stable GitHub release in `desigrit/sunno-macos`. No automatic checks, downloads,
system-profile submission, audio or transcript uploads are enabled.

Both the appcast and the ZIP require Ed25519 signatures. The verification key is public and
committed in `config/Updater.xcconfig`; the private seed is stored in the repository's encrypted
`SPARKLE_PRIVATE_KEY` Actions secret. Keep a secure backup. Do not generate a replacement key
for an established release: installed clients trust the original public key.

## Build and publish with GitHub Actions

The **Build and publish macOS release** workflow runs on GitHub's native Apple silicon runner.
It does not need an SSH connection, an awake personal Mac or an unlocked login Keychain.

1. Increment `SUNNO_RELEASE_VERSION`, `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
   `project.yml` for each release. Release 1.0.92.0 uses Apple's three-part bundle version
   1.0.92 and build 5. Settings, the ZIP and the GitHub tag use the shared release number.
   The build number is monotonic and identical in the command-line and Xcode builds.
2. Commit and push the release sources to `main`.
3. In GitHub, select **Actions > Build and publish macOS release > Run workflow**, using `main`.
   Alternatively, run `gh workflow run release-macos.yml --repo desigrit/sunno-macos --ref main`.
4. The workflow builds the app and all three native speech helpers, packages the Python runtime,
   runs updater checks, verifies code signatures after extracting the ZIP, loads its native
   Python dependencies, and independently verifies the archive and feed signatures.
5. Only after those checks pass, it creates the version tag at the exact source commit. The ZIP,
   appcast and SHA256SUMS upload to a draft, then the complete release becomes public.

Packages are stored directly in GitHub Releases. The workflow does not retain large Actions
artifacts or dependency caches. Resolved Python dependency versions are included inside the app
at `Contents/Resources/engine/python/sunno-python-requirements.txt`.

### Signing credentials

Repository Actions secrets are configured once and reused for subsequent releases:

| Secret | Contents |
| --- | --- |
| `SPARKLE_PRIVATE_KEY` | Base64 encoding of the 32-byte Ed25519 private seed, as exported by Sparkle 2.10.1. |
| `MACOS_SIGNING_P12_BASE64` | Base64 encoding of the encrypted code-signing certificate and private key in a PKCS#12 file. |
| `MACOS_SIGNING_P12_PASSWORD` | Password for that PKCS#12 file. |

`config/MacReleaseSigning.pem` contains only the public code-signing certificate. Its fingerprint
selects the imported identity. Each job imports the identity into a temporary runner Keychain,
grants access to Apple's signing tools, then removes the Keychain when it finishes. Sparkle reads
its private seed through standard input. Neither private key is committed or uploaded as an artifact.

The workflow runs only when manually dispatched on `main`, serializes releases and refuses to
overwrite an existing release. Pull-request CI has no access to the release secrets.

### Local packaging

Install Python's `cryptography` package for independent release verification. A local Mac can
still package with `bash scripts/package-app.sh`. Supply the original Sparkle seed through
`SUNNO_SPARKLE_PRIVATE_KEY`, or restore it into the login Keychain under
`com.desigrit.sunno.sparkle`. `scripts/configure-updater-key.sh` checks that a local Keychain key
matches the committed public key. Set `SUNNO_IDENTITY` to the original signing certificate's
fingerprint. Commit the release sources and tag them before running `scripts/publish-release.sh`.

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
