#!/bin/bash
# Build, install, and launch. `./Scripts/run.sh debug` for a debug build.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

./Scripts/build-app.sh "${1:-release}"
open -a "${SWIFTTERM_INSTALL_DIR:-/Applications}/swiftTerm.app"
