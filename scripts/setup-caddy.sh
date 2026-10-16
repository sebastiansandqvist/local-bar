#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# An optional argument points to an existing Caddyfile. Later runs remember it.
swift run LocalBarSetup "$@"
# Port 80 requires a system service on macOS. Authenticate once during setup.
BIN_DIR="$(swift build --show-bin-path)"
sudo "$BIN_DIR/LocalBarSetup" --install-service "$HOME/Library/Application Support/Local Bar"
