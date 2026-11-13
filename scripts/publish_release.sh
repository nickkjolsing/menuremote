#!/bin/bash
# Publish only a release for this exact checkout; safe to retry failed uploads.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${GH_REPO:?Set GH_REPO to owner/repository}"

VERSION="$(cat version.txt)"
TAG="v$VERSION"
ARCHIVE="MenuRemote-${VERSION}-macOS-arm64.zip"
REVISION="$(git rev-parse HEAD)"
python3 scripts/verify_release.py "dist/$ARCHIVE" "$VERSION" "$REVISION"
if [[ -n "${EXPECTED_RELEASE_SHA:-}" && "$EXPECTED_RELEASE_SHA" != "$REVISION" ]]; then
    echo "The new release targets another commit; rerun Build at that release tag." >&2
    exit 1
fi

# Includes drafts. A normal push can update the release PR without cutting a release.
TAGS="$(gh release list --limit 100 --json tagName --jq '.[].tagName')"
if ! grep -Fxq "$TAG" <<< "$TAGS"; then
    echo "No $TAG release to publish."
    exit 0
fi
TAG_REVISION="$(gh api "repos/$GH_REPO/commits/$TAG" --jq .sha)"
if [[ "$TAG_REVISION" != "$REVISION" ]]; then
    echo "$TAG belongs to another commit; this build will not be uploaded."
    exit 0
fi

# Never publish an updater-enabled release without its signed feed. Do this only
# after finding a matching release, so ordinary pushes can still open release PRs.
python3 scripts/verify_release.py "dist/$ARCHIVE" "$VERSION" "$REVISION" --require-appcast

VERIFY_DIR="$(mktemp -d)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
ASSETS="$(gh release view "$TAG" --json assets --jq '.assets[].name')"
for asset in "$ARCHIVE" "$ARCHIVE.sha256" appcast.xml; do
    if grep -Fxq "$asset" <<< "$ASSETS"; then
        gh release download "$TAG" --pattern "$asset" --dir "$VERIFY_DIR"
        # Never replace previously uploaded bytes, including on retries.
        cmp "dist/$asset" "$VERIFY_DIR/$asset"
    else
        gh release upload "$TAG" "dist/$asset"
    fi
done

IS_DRAFT="$(gh release view "$TAG" --json isDraft --jq .isDraft)"
if [[ "$IS_DRAFT" == true ]]; then
    gh release edit "$TAG" --draft=false
fi
echo "Published $TAG with verified app, checksum, and signed update feed."
