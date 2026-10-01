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
    crates/secret_redaction/src/*.swift
    app/src/terminal/TerminalSession.swift
    Tests/HarnessSupport.swift
    # Named individually rather than globbed, and deliberately: `Theme.swift` sits beside it and imports
    # AppKit, so adding the directory would let a UI framework into the harnesses by the back door.
    crates/warpui_core/src/ChromeSettings.swift
    crates/warpui_core/src/Keymap.swift
    crates/warpui_core/src/SettingsStore.swift
)

if [ "${1:-}" = "--exec" ]; then
    shift
    name=$1
    shift
    # The wire contract harness is Foundation-only by design: it compiles the transport DTOs and
    # nothing else, so a contract type that reached for TerminalGrid, AppKit or a view would stop
    # it compiling. That is the whole point of C0, and it is why this harness gets its own source
    # list instead of the shared one.
    if [ "$name" = "wire-contract-test" ]; then
        SOURCES=(
            crates/shared_session/src/*.swift
            crates/cloud_objects/src/*.swift
        )
    fi
    if [ "$name" = "sharing-offline-test" ]; then
        SOURCES=()
        while IFS= read -r file; do SOURCES+=("$file"); done < <(
            rg --files app/src crates -g '*.swift' | rg -v '/SwiftTermApp.swift$')
    fi
    if [ "$name" = "static-share-test" ]; then
        SOURCES+=(crates/shared_session/src/*.swift crates/cloud_objects/src/*.swift
                  app/src/cloud_object/StaticShareExport.swift)
    fi
    if [ "$name" = "stream-publisher-test" ]; then
        SOURCES=(crates/shared_session/src/*.swift crates/cloud_objects/src/*.swift
                 app/src/terminal/shared_session/StreamPublisher.swift)
    fi
    if [ "$name" = "terminal-renderer-test" ] || [ "$name" = "block-collapse-test" ] \
        || [ "$name" = "command-editor-undo-test" ]; then
        SOURCES+=(
            crates/warpui_core/src/Theme.swift
            app/src/terminal/view/TerminalFont.swift
            app/src/terminal/view/TerminalRenderer.swift
        )
    fi
    if [ "$name" = "block-collapse-test" ] || [ "$name" = "command-editor-undo-test" ]; then
        SOURCES+=(
            crates/shared_session/src/*.swift
            crates/cloud_objects/src/*.swift
            app/src/terminal/shared_session/*.swift
            app/src/account/AccountController.swift
            app/src/account/SignInFlow.swift
            crates/warpui_core/src/TextIntelligence.swift
            app/src/workspace/Appearance.swift
            app/src/terminal/view/TerminalSurfaceView.swift
            app/src/terminal/view/TerminalCoordinator.swift
            app/src/terminal/view/CommandEditorView.swift
            app/src/terminal/view/BlockMenuPopover.swift
            app/src/terminal/view/CompletionPopover.swift
            app/src/terminal/view/TerminalFindBar.swift
        )
    fi
    if [ "$name" = "git-review-test" ]; then
        SOURCES+=(crates/git/src/*.swift app/src/code_review/CodeReviewCoordinator.swift)
    fi
    if [ "$name" = "sign-in-test" ]; then
        SOURCES+=(crates/shared_session/src/*.swift crates/cloud_objects/src/*.swift
                  app/src/account/AccountController.swift app/src/account/SignInFlow.swift)
    fi
    if [ "$name" = "cloud-objects-test" ]; then
        # The cloud client builds on the wire DTOs, so it needs both — and it needs them *without*
        # the view layer, which is the property being guarded: a client that reached for AppKit
        # would stop compiling here.
        SOURCES+=(
            crates/shared_session/src/*.swift
            crates/cloud_objects/src/*.swift
        )
    fi
    if [ "$name" = "control-lease-test" ]; then
        # The control lease is a pure state machine over the wire's own counters. It needs the
        # contract and nothing else — no terminal, no socket, no view — which is the property that
        # makes it testable at all.
        SOURCES+=(crates/shared_session/src/*.swift)
    fi
    if [ "$name" = "remote-key-test" ]; then
        # `RemoteKeyBytes` bridges the contract's logical keys and the terminal's escape grammar, so
        # it needs both. It lives in the app layer rather than under `crates/warp_terminal/src/model`
        # on purpose: that directory is in every harness's default source list, and a file there that
        # referenced the contract would stop all forty of them compiling — which is exactly what
        # happened before this was moved.
        SOURCES+=(crates/shared_session/src/*.swift app/src/terminal/shared_session/RemoteKey.swift)
    fi
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
total=${#NAMES[@]}
for name in "${NAMES[@]}"; do
    if [ -f "$BIN/$name.failed" ]; then
        failed=$((failed + 1))
        echo
        echo "── $name ──"
        sed -n '1,60p' "$BIN/$name.log"
    fi
done

# The wire contract has two independent implementations: the Swift DTOs and the TypeScript
# validators in contracts/ts. The gate is that both agree on the same bytes and reject the same
# cases, and a Swift-only run cannot notice the other half drifting.
echo
if command -v node >/dev/null 2>&1; then
    total=$((total + 1))
    if node contracts/ts/check-fixtures.ts > "$BIN/contracts.log" 2>&1; then
        printf '\033[32mok\033[0m    %-28s\n' "contracts/check-fixtures"
    else
        failed=$((failed + 1))
        echo
        echo "── contracts/check-fixtures ──"
        sed -n '1,60p' "$BIN/contracts.log"
    fi
else
    printf '\033[33mskip\033[0m  %-28s %s\n' "contracts/check-fixtures" "no node on PATH"
fi

echo
if [ "$failed" -ne 0 ]; then
    echo "✗ $failed of $total checks failed" >&2
    exit 1
fi
echo "✓ all $total checks pass"
