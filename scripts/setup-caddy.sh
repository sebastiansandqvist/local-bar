#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# An optional argument points to an existing Caddyfile. Later runs remember it.
swift run LocalBarSetup "$@"
