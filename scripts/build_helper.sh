#!/bin/bash
# Build a relocatable, private Python helper. Nothing is installed on users' Macs.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -m)" != arm64 ]]; then
    echo "Build the Apple silicon helper on an arm64 Mac." >&2
    exit 1
fi
if ! command -v uv >/dev/null; then
    echo "Building from source requires uv; downloaded apps do not." >&2
    exit 1
fi

export UV_CACHE_DIR="${UV_CACHE_DIR:-$PWD/.build/uv-cache}"
export PYINSTALLER_CONFIG_DIR="$PWD/.build/pyinstaller-cache"
export MACOSX_DEPLOYMENT_TARGET=14.0
PYTHON_VERSION="$(cat Support/helper-python-version.txt)"
VENV="$PWD/.build/helper-venv"
uv venv --clear --python "$PYTHON_VERSION" --managed-python "$VENV"
uv pip sync --python "$VENV/bin/python" --require-hashes --only-binary :all: Support/helper-requirements.txt

# One directory, not a self-extracting executable: no temporary runtime or downloads.
# pyatv loads protocol modules dynamically, so include all of its submodules.
"$VENV/bin/python" -m PyInstaller --noconfirm --clean \
    --distpath build/helper --workpath .build/helper-work Support/MenuRemoteHelper.spec

"$VENV/bin/python" scripts/helper_notices.py build/helper/ThirdPartyNotices
