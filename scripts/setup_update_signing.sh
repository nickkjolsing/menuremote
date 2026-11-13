#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
KEY_FILE="${MENU_REMOTE_UPDATE_KEY_FILE:-$HOME/Library/Application Support/MenuRemote/Updates/private-key}"
swift scripts/create_update_key.swift "$KEY_FILE" Support/SparklePublicKey.txt
