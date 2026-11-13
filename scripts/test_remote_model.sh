#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library \
    Sources/MenuRemote/Bridge.swift \
    Sources/MenuRemote/RemoteModel.swift \
    tests/Swift/RemoteModelTests.swift \
    -o "$TEST_DIR/RemoteModelTests"
"$TEST_DIR/RemoteModelTests"
