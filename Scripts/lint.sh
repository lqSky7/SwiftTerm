#!/bin/bash
# Lint the whole project. `--fix` auto-corrects the mechanical subset first.
# Formatting is a separate concern and there is no formatter — see .swiftlint.yml.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

command -v swiftlint >/dev/null || {
    echo "✗ swiftlint not found. Install it with:  brew install swiftlint" >&2
    exit 2
}

[ "${1:-}" = "--fix" ] && swiftlint --fix --quiet

if ! swiftlint lint --quiet; then
    echo
    echo "Lint errors above. Warnings do not block; errors do." >&2
    exit 1
fi

# The pure-model invariant is enforced by the harnesses at compile time, but a file nothing
# harnesses yet would slip through, so the grep is still the honest statement of the rule.
# `ChromeSettings.swift` is named individually because `Theme.swift` sits beside it and is *meant* to
# import AppKit — the directory is not the unit of purity here, the file is.
PURE_PATHS=(
    crates/warp_terminal/src/model/
    crates/warpui_core/src/ChromeSettings.swift
    crates/warpui_core/src/SettingsStore.swift
)

if grep -rlE '^import (AppKit|SwiftUI|Cocoa)' "${PURE_PATHS[@]}" 2>/dev/null | grep -q .; then
    echo "✗ a model file imports a UI framework:" >&2
    grep -rlE '^import (AppKit|SwiftUI|Cocoa)' "${PURE_PATHS[@]}" >&2
    exit 1
fi

echo "✓ lint-clean"
