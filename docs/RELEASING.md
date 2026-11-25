# Releasing

MenuRemote uses release-please to publish versioned macOS apps.

## One-time setup

In GitHub **Settings → Actions → General**, enable **Allow GitHub Actions to create and approve pull requests**. Squash-merge PRs so their titles become the commits on `main`.

The built-in `GITHUB_TOKEN` is sufficient for releases. It does not trigger checks on bot-created PRs. If those checks are required, set an Actions secret named `RELEASE_PLEASE_TOKEN` using a fine-grained token with repository **Contents**, **Issues**, and **Pull requests** write access. The workflow uses it automatically when present.

Updates use [Sparkle](https://sparkle-project.org/) with signed archives and signed feeds. The public signing key lives in `Support/SparklePublicKey.txt`. The corresponding private key must be backed up securely and configured as the repository Actions secret **`SPARKLE_PRIVATE_KEY`**. Never commit the private key or generate a replacement for an already distributed public key.

For the original signing machine, the private key is saved at `~/Library/Application Support/MenuRemote/Updates/private-key` with owner-only permissions. To copy it into GitHub's **Settings → Secrets and variables → Actions → New repository secret**, run:

```sh
pbcopy < "$HOME/Library/Application Support/MenuRemote/Updates/private-key"
```

Paste into the secret value and name it `SPARKLE_PRIVATE_KEY`. On another machine, restore this same private key to that path, or set `MENU_REMOTE_UPDATE_KEY_FILE` to its location. `bash scripts/setup_update_signing.sh` verifies that an existing private key matches the public key; it refuses to create a new identity if the public key already exists.

## Ship

| Squash commit / PR title | Version change |
| --- | --- |
| `fix: reconnect after sleep` / `perf:` | Patch |
| `feat: add a remote control` | Minor |
| `feat!: change pairing storage` | Major |
| `docs:`, `chore:`, `ci:`, `refactor:`, `test:`, `build:` | No release on their own |

1. Merge a feature or fix into `main`.
2. After the build passes, release-please opens or updates a release PR with `version.txt`, the manifest, and `CHANGELOG.md`. The first release is **1.0.0**.
3. Review and merge that PR. The workflow creates `vX.Y.Z` and a draft GitHub Release, attaches the verified ZIP, checksum, and signed `appcast.xml`, then publishes it.

The app version comes from `version.txt`; the app bundle also records its source commit. The release job uses the exact ZIP checked by the build job. It rejects a mismatched version, commit, architecture, or checksum, and never overwrites an existing asset.

The app checks `https://github.com/nickkjolsing/menuremote/releases/latest/download/appcast.xml`. Each release's feed points to its own versioned archive, so GitHub hosts both the feed and downloads. There is no separate server or Pages deployment. The feed embeds release notes and declares minimum macOS and hardware requirements. Sparkle verifies the feed and archive signatures before installing.

Checks and installation are manual. The app does not prompt for automatic checks, download updates at launch, or opt users into automatic installation. Users choose **Check for Updates…**, then approve downloading and installing the offered update. Existing users must install the first updater-enabled release manually.

Pull requests build and test with disposable signing keys, without receiving the production signing secret. A matching release cannot be published without a signed feed; if signing was not configured for its build, add the secret and rebuild at the release tag.

If an upload fails, use **Re-run failed jobs** on that workflow run. This reuses the original build artifact (retained for 14 days), verifies existing assets, and finishes the draft. **Build → Run workflow** on `main` can also retry release automation; assets are attached only when their source commit matches the release tag.

If `main` has moved ahead of an unfinished release, `gh workflow run build.yml --ref vX.Y.Z` builds that exact tag and finishes its draft. Existing assets must still match; changed bytes are rejected.

## Local check

```sh
uv venv --python "$(cat Support/helper-python-version.txt)" --managed-python .venv
uv pip sync --python .venv/bin/python --require-hashes --only-binary :all: Support/helper-requirements.txt
.venv/bin/python -m unittest discover -s tests -v
bash scripts/test_remote_model.sh
bash scripts/package_release.sh
bash scripts/test_text_entry.sh
python3 scripts/test_updater.py
```

Output: `dist/MenuRemote-X.Y.Z-macOS-arm64.zip`, its `.sha256` file, and signed `dist/appcast.xml` when a signing key is available. Packaging verifies the extracted app's signature and executable permissions, including Sparkle's helpers. It runs a relocated copy of the Python helper with network, Homebrew, source checkout, and external Python access blocked. This exercises startup, native crypto, protocol imports, command exchange, and existing credential loading. Packaging without a private key is allowed for contribution builds, but cannot be published as a release.

## Bundled helper

No custom OS image or container is needed. `MenuRemote.app` is a directory containing the Swift executable, Sparkle, and `Contents/Helpers/MenuRemoteHelper.app/`. That nested bundle contains a PyInstaller executable, its private Python shared library, standard library, and Python dependencies. Its code and data use the macOS bundle layout for signing. Swift starts its executable directly and exchanges newline-delimited JSON over stdin/stdout, just as it previously did with the installed Python script.

`scripts/build_helper.sh` runs only on the arm64 build machine. uv installs the exact Python patch from `Support/helper-python-version.txt` and verifies every package against the versions and hashes in `Support/helper-requirements.txt`. PyInstaller collects the helper into one directory and rewrites native library paths for relocation. It does not use a self-extracting executable. Python, Homebrew, uv, pip, and a compiler are not required on the user's Mac. Runtime files remain in the app bundle; credentials stay in Application Support. Old installed venvs are ignored and left intact.

Keep `srptools==1.0.1` while using pyatv 0.18.0. The srptools 2 API breaks new pairing ([upstream issue](https://github.com/postlund/pyatv/issues/2940)); imports and previously saved credentials do not exercise this path. Source tests perform real HAP and legacy SRP handshakes against an in-process server. The packaged helper's offline self-test also initializes both pairing paths before a release can pass verification.

Dependency versions and license notices ship in `Contents/Resources/ThirdPartyNotices/`. Dependencies, including security fixes, update through app releases. To change them, edit `Support/helper-requirements.in` or the Python patch file, then regenerate and review the lock file on an arm64 Mac:

```sh
uv pip compile Support/helper-requirements.in \
  --python "$(cat Support/helper-python-version.txt)" \
  --python-platform aarch64-apple-darwin --generate-hashes \
  --output-file Support/helper-requirements.txt
```

Run the local checks after changing the lock. If upgrading beyond Python 3.13 or pyatv 0.18.0, update the release verifier and helper smoke check as well.

The updater integration tests compile disposable apps with separate bundle identifiers and temporary signing keys, serve them on loopback, and exercise installation with relaunch, an up-to-date app, a tampered archive, a tampered feed, and an unavailable feed. They do not launch or replace the installed MenuRemote, use the production private key, or contact Apple TVs.

## Apple signing

Current downloads are **ad-hoc signed**, with no Apple Developer credentials required. They are not notarized, so Gatekeeper may block them. Developer ID signing and Apple notarization are needed for the normal download-and-open experience; the release workflow does not claim to provide either.

Developer ID is optional at build time. After installing a Developer ID Application certificate and its private key in the build machine's keychain, use:

```sh
MENU_REMOTE_CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  bash scripts/package_release.sh
```

PyInstaller signs the helper and its native libraries with that identity and hardened runtime. The app signing script re-signs Sparkle's nested components from the inside out, then signs the outer app with hardened runtime and a secure timestamp. With the variable unset, the build stays ad-hoc signed. Sparkle's Ed25519 update key is separate and remains required for publishing either kind of build.

Developer ID signing alone does not notarize a release. Future notarization also requires submitting the signed app to Apple's notary service, stapling the accepted ticket before creating the final ZIP/checksum/appcast, and configuring certificate/notary credentials in CI. No Apple credentials or notarization submissions are used by the default workflow.
