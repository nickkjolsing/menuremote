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
python3 -m venv .venv
.venv/bin/python -m pip install -r tests/requirements.txt
.venv/bin/python -m unittest discover -s tests -v
bash scripts/test_remote_model.sh
bash scripts/package_release.sh
python3 scripts/test_updater.py
```

Output: `dist/MenuRemote-X.Y.Z-macOS-arm64.zip`, its `.sha256` file, and signed `dist/appcast.xml` when a signing key is available. Packaging verifies the extracted app's signature and executable permissions, including Sparkle's helpers. Packaging without a private key is allowed for contribution builds, but cannot be published as a release.

The updater integration tests compile disposable apps with separate bundle identifiers and temporary signing keys, serve them on loopback, and exercise installation with relaunch, an up-to-date app, a tampered archive, a tampered feed, and an unavailable feed. They do not launch or replace the installed MenuRemote, use the production private key, or contact Apple TVs.

## Apple signing

Current downloads are **ad-hoc signed**, with no Apple Developer credentials required. They are not notarized, so Gatekeeper may block them. Developer ID signing and Apple notarization are needed for the normal download-and-open experience; the release workflow does not claim to provide either.
