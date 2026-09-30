# H — headless frontend implementation handoff

User selected **implementation handoff first**. No console frontend is implemented in R1.
Read AGENTS.md, ponytail, tinycast rules, warp_features.md #41, and local Warp `crates/warp_tui/`.
Implement one package at a time. No local IPC daemon (#27), server-created PTYs, remote container
provisioning, daemonization, AI components or new native UI. First supported host is macOS 26+;
Linux portability is a separate phase, not a conditional compatibility tree in current app code.

## H1 — one shared terminal module (mechanical prerequisite)

Owner files: Package.swift, crates/warp_terminal/src/**, Scripts/run-tests.sh, Tests/** and the
app imports needed to consume that module. Move app/src/terminal/TerminalSession.swift into
crates/warp_terminal/src/local_tty/TerminalSession.swift with `git mv`; do not duplicate it.
Add a Foundation/Darwin-only library target `WarpTerminal`; native target depends on it and
stops compiling those sources directly. Mark only consumed symbols/members/initializers `package`
and import WarpTerminal at callers. Do not change runtime semantics, appearance or hook protocol.
Harness direct compilation adds `-package-name SwiftTerm` so package visibility remains testable.
Do not expose AppKit/editor/font/settings types through the core. No cross-feature imports.

Gate: all current harnesses, native Debug/release and model purity check pass. Diff must be limited
to movement/import/access control/package lists. Build/install native app and stop for user testing.
This module split is necessary for two executables; never copy terminal source into a new target.

## H2 — minimal console frontend

Owner: crates/warp_tui/{index.md,src/**}, Package.swift target `SwiftTermHeadless`, new standalone
headless harnesses, Scripts/index.md and docs for invocation. Invoke `swiftterm-headless` (installed
CLI name for SwiftTermHeadless); require interactive stdin/stdout TTYs. Reject redirected input
with status 2. Arguments: `--cwd <absolute-directory>`, `--shell <absolute-executable>`, `--help`.
Unknown flags exit 2. Use current env/default shell and cwd if omitted. No cloud settings in H2.

- [ ] Save parent termios and enter raw mode; use TIOCGWINSZ before PTY spawn.
- [ ] Own TerminalSession and PTY lifecycle on MainActor, reuse parser/grids/blocks/bootstrap.
- [ ] Forward stdin bytes to child PTY; child shell line editor owns the draft in this increment.
- [ ] Project submitted output + active header grid into host-sized fixed cells, newest visible rows.
- [ ] In alternate-screen mode project only the active screen, no block chrome/padding.
- [ ] Render SGR, grapheme width/continuations and cursor at fixed coordinates; emit changed rows only.
- [ ] Normal prompt cursor follows the header grid even though native detached-editor cursor policy differs.
- [ ] Preserve bracketed paste/mouse modes and ESC sequences without appending newlines.
- [ ] Watch SIGWINCH via async-safe self-pipe; handler writes a byte, owned reader task performs resize.
- [ ] Read stdin off-main into a bounded AsyncStream; no DispatchQueue/DispatchSource/OperationQueue.
- [ ] Child exit returns its status; restore termios/cursor/mouse/alternate modes in every shutdown path.
- [ ] HUP/TERM/INT cleanup is idempotent; child and readers cannot outlive frontend ownership.

Recorded H2 divergence: pass-through shell editing replaces native NSTextView. No claim of rich
editor undo, inline native recommendations, block mouse menus or automatic SSH interception in H2.
These depend on H3. Never suppress a prompt unless the frontend renders its cursor/input correctly.
A Swift standalone entrypoint uses Foundation's async main, not NSApplication or a window server.

Gate: a nested scratch PTY driver (no app launch) compares rows/colors/cursor for bash/zsh, Unicode
wide/combining characters, wrapped output, nano-style alternate screens, paste and resize bursts.
Check invalid cwd/shell, non-TTY stdin, signal/child exit, clean terminal restoration, cancellation
and output backpressure. Measure idle CPU and bounded RSS after 100,000 output lines. Build CLI;
user runs interactive programs. Do not proceed to H3 automatically.

## H3 — native feature parity, separate approval/test increment

Owner: crates/warp_tui/src/** and narrowly justified shared pure command-editor state; no AppKit in
headless target. Reuse CompletionEngine/HistoryNavigator/CommandSubmission/RemoteShellBootstrap,
not a new completion parser. Specify draft grapheme editing/selection and bounded undo before code.
Route committed prompt submissions through TerminalSession.submission; raw input still goes to PTY.
Add keyboard block navigation/collapse/context actions without borrowing native views. Preserve
H2 rendering/terminal restoration tests. Browser sharing can depend on shared_session DTOs after
C0/B2; never bypass native/device auth or invent a second network protocol.

## H4 — optional portability (not in current scope)

Inventory Darwin PTY/process/termios APIs before choosing a portable core or Rust reuse. No Linux
support claim until Linux PTY harnesses pass. Copying Warp Rust internals requires license review
and a narrow FFI boundary; it is not justified merely to render a console on macOS.

Each owner reports changed files, behavior, tests, measured limits and remaining gaps. Every new
directory gets index.md; update phase checkboxes only with evidence. Signed commits use `-s -S`.
