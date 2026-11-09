# Releasing

MenuRemote uses release-please to publish versioned macOS apps.

## One-time setup

In GitHub **Settings → Actions → General**, enable **Allow GitHub Actions to create and approve pull requests**. Squash-merge PRs so their titles become the commits on `main`.

The built-in `GITHUB_TOKEN` is sufficient for releases. It does not trigger checks on bot-created PRs. If those checks are required, set an Actions secret named `RELEASE_PLEASE_TOKEN` using a fine-grained token with repository **Contents**, **Issues**, and **Pull requests** write access. The workflow uses it automatically when present.

## Ship

| Squash commit / PR title | Version change |
| --- | --- |
| `fix: reconnect after sleep` / `perf:` | Patch |
| `feat: add a remote control` | Minor |
| `feat!: change pairing storage` | Major |
| `docs:`, `chore:`, `ci:`, `refactor:`, `test:`, `build:` | No release on their own |

1. Merge a feature or fix into `main`.
2. After the build passes, release-please opens or updates a release PR with `version.txt`, the manifest, and `CHANGELOG.md`. The first release is **1.0.0**.
3. Review and merge that PR. The workflow creates `vX.Y.Z` and a draft GitHub Release, attaches the verified ZIP and checksum, then publishes it.

The app version comes from `version.txt`; the app bundle also records its source commit. The release job uses the exact ZIP checked by the build job. It rejects a mismatched version, commit, architecture, or checksum, and never overwrites an existing asset.

If an upload fails, use **Re-run failed jobs** on that workflow run. This reuses the original build artifact (retained for 14 days), verifies existing assets, and finishes the draft. **Build → Run workflow** on `main` can also retry release automation; assets are attached only when their source commit matches the release tag.

If `main` has moved ahead of an unfinished release, `gh workflow run build.yml --ref vX.Y.Z` builds that exact tag and finishes its draft. Existing assets must still match; changed bytes are rejected.

## Local check

```sh
python3 -m unittest discover -s tests -v
bash scripts/package_release.sh
```

Output: `dist/MenuRemote-X.Y.Z-macOS-arm64.zip` and its `.sha256` file. Packaging verifies the extracted app's signature and executable permissions.

## Apple signing

Current downloads are **ad-hoc signed**, with no Apple Developer credentials required. They are not notarized, so Gatekeeper may block them. Developer ID signing and Apple notarization are needed for the normal download-and-open experience; the release workflow does not claim to provide either.
