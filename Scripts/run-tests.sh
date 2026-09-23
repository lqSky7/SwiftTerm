#!/bin/bash
# The test suite. There is no XCTest target: each harness compiles the shipped sources it
# guards, so a harness that stops compiling means a decision leaked out of a pure layer.
#
# Never join a compile and its run with `&&`: `set -e` ignores a failure in a non-final
# AND-OR list member, which is how a suite reports success over a harness that never built.

set -uo pipefail

# Absolute: the workers re-enter this script after the cd, where a relative $0 would not resolve.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.." || exit 1

TIMEOUT="${SWIFTTERM_TEST_TIMEOUT:-60}"
BIN="${TMPDIR:-/tmp}/swiftterm-harness"
mkdir -p "$BIN"

# Every harness guards the same layers, so the source set is one list. If a file under
# crates/warp_terminal/src/model/ ever imports AppKit or SwiftUI, every harness stops compiling —
# that is the gate, and it is why the harnesses never link the view layer.
SOURCES=(
    crates/warp_terminal/src/model/*.swift
    crates/warp_terminal/src/local_tty/*.swift
    crates/warp_terminal/src/shell/*.swift
    crates/warp_terminal/src/bootstrap/*.swift
    app/src/terminal/TerminalSession.swift
    Tests/HarnessSupport.swift
    # Named individually rather than globbed, and deliberately: `Theme.swift` sits beside it and imports
    # AppKit, so adding the directory would let a UI framework into the harnesses by the back door.
    crates/warpui_core/src/ChromeSettings.swift
    crates/warpui_core/src/SettingsStore.swift
)

if [ "${1:-}" = "--exec" ]; then
    shift
    name=$1
    shift
    : > "$BIN/$name.running"
    trap 'rm -f "$BIN/$name.running"' EXIT
    fail() {
        printf '\033[31mFAIL\033[0m  %-28s %s\n' "$name" "$1"
        : > "$BIN/$name.failed"
        exit 0
    }
    if ! swiftc -swift-version 6 -warnings-as-errors \
        "${SOURCES[@]}" "Tests/$name.swift" -o "$BIN/$name" > "$BIN/$name.log" 2>&1; then
        fail "did not compile"
    fi
    "$BIN/$name" > "$BIN/$name.log" 2>&1 &
    pid=$!
    # macOS ships no `timeout`, so the worker polls; a wedged harness must fail, not stall.
    ticks=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -ge $((TIMEOUT * 5)) ]; then
            { pkill -KILL -P "$pid"; kill -KILL "$pid"; wait "$pid"; } 2>/dev/null
            printf '\n[run-tests] killed after %ss without finishing\n' "$TIMEOUT" >> "$BIN/$name.log"
            fail "timed out after ${TIMEOUT}s"
        fi
        ticks=$((ticks + 1))
        sleep 0.2
    done
    wait "$pid"
    status=$?
    if [ "$status" -gt 128 ]; then fail "crashed (signal $((status - 128)))"; fi
    if [ "$status" -ne 0 ]; then fail "assertion failed"; fi
    printf '\033[32mok\033[0m    %-28s\n' "$name"
    exit 0
fi

# macOS ships bash 3.2, so no `mapfile` and no `ls --`.
NAMES=()
for path in Tests/*-test.swift; do
    [ -e "$path" ] || continue
    NAMES+=("$(basename "$path" .swift)")
done
if [ "${#NAMES[@]}" -eq 0 ]; then
    echo "✗ no harnesses found in Tests/" >&2
    exit 1
fi

rm -f "$BIN"/*.failed "$BIN"/*.running
printf '%s\n' "${NAMES[@]}" | xargs -P "$(sysctl -n hw.ncpu)" -I {} "$SELF" --exec {}

failed=0
for name in "${NAMES[@]}"; do
    if [ -f "$BIN/$name.failed" ]; then
        failed=$((failed + 1))
        echo
        echo "── $name ──"
        sed -n '1,60p' "$BIN/$name.log"
    fi
done

echo
if [ "$failed" -ne 0 ]; then
    echo "✗ $failed of ${#NAMES[@]} harnesses failed" >&2
    exit 1
fi
echo "✓ all ${#NAMES[@]} harnesses pass"
