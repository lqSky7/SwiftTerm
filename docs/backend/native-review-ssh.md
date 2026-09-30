# R1 — local Git review and SSH bootstrap

Requested batch: implement native review + #19, then prepare headless/backend/website handoffs.
This explicitly requested batch is one delivery; future implementation phases stop for user testing.
No app launch or computer-use testing. New behavior remains subject to human acceptance.

## Git review behavior

The active pane's pinned prompt shows `(+234 -12)`. Clicking it opens the trailing native review
sidebar. Both sidebars use the existing window backdrop, material and sidebar opacity; there is
no second scrim/material or new appearance preference. A one-physical-pixel outline follows the terminal
continuous corners, including trailing corners when review is open, without changing grid geometry.
Toolbar actions are native interactive Liquid Glass circles. Terminal width changes once; the review
sidebar alone animates. The pane used for review follows the active pane and working directory.

Review includes staged, unstaged and untracked files, old/new line numbers, unified text and
file-level Stage/Unstage. Counts sum index and worktree differences separately, so a partially
staged file can appear twice. Binary files appear with a Binary label and Git's textual notice.
Renames appear as deletion/addition, keeping NUL parsing and path handling unambiguous. Paths are
literal argv pathspecs, never shell commands. Non-UTF-8 filenames are skipped with a limited-total
indicator; displaying replacement characters must never stage a different filename. No discard/reset-worktree action is included.

Refresh happens on prompt-ready (after command completion), context/pane changes, window
activation and the sidebar Refresh button;
there is no idle polling or recursive directory watcher. Title-only events do not restart the
refresh debounce; removed selections cancel their old patch task. Changes from another app need Refresh
or the next prompt. Only the active pane is refreshed; inactive labels refresh upon activation.
A patch is fetched only after selecting a file, one document retained at a time. Selection/close
cancels reads; index mutations have a separate lifetime, so closing the sidebar does not cancel
staging. Switching directories clears old review data before the new lookup completes.

Warp references inspected locally: `app/src/code_review/diff_size_limits.rs`, `hidden_lines.rs`,
`code_review_view.rs`, `git_actions.rs`. Match its on-demand reads and large-diff collapse. Limits:
4,375,000 patch bytes, 2,187,500 soft threshold, 10,000 soft rows; 50,000 hard preview rows,
20,000 decoded bytes per visible line, 10,000 summary files, 16 MiB total untracked reads and
15 seconds per Git command. NSTableView recycles visible cells; rows index one byte buffer.
Git stdout uses temporary files to avoid pipe deadlocks; the 25 ms producer check can overshoot
the disk limit briefly, while retained data stays capped. No external diff/textconv tools run.

Recorded divergence: Warp can refuse unrenderable files; this native increment offers a labelled
bounded preview instead. No syntax coloring, side-by-side mode, hunk staging, GitHub PR comments
or remote repository review yet. Do not call this the full #26 implementation. A future Git
phase must preserve these bounds and file-mutation lifetimes.

## SSH bootstrap behavior

Native prompt submissions of literal `ssh user@host` or `/usr/bin/ssh user@host`, with recognized
connection options, use a short local helper installed beside the existing shell integration.
The helper invokes the same SSH executable through its normal PATH (or explicit absolute path),
adds a PTY request and sends a quoted inline remote bootstrap as argv. Nothing feeds a script
into the interactive stdin. Authentication, host keys, config, proxy jump, agent forwarding,
resize, input and network transport remain OpenSSH's responsibility. No host-key bypass is added.
No second authentication attempt or automatic reconnect is performed.

Recognized value flags: `-p -l -i -F -J -c -m -b -o`; simple flags: `-4 -6 -A -a -C -v -vv -vvv
-q -t`. `-o` is limited to the connection keys in RemoteShellBootstrap.submission. Shell quoting,
expansions, aliases, attached options, multiple statements, explicit remote commands, tunnels,
control operations, `-T/-N/-W`, and unknown options bypass the bootstrap. `command ssh host` is
an explicit bypass. Configured RemoteCommand can conflict with bootstrap; OpenSSH's error is
shown, with no silent retry. Do not intercept scp/sftp. Nested SSH currently stays ordinary SSH.

The remote launcher creates an umask-077 temporary directory and chains the user's startup files
for zsh/bash/fish using the existing integration scripts. It removes temporary hooks on normal
exit/signals; a killed host can leave its private directory (no persistent dotfile edits or remote
binary installation). Unsupported shells use a normal interactive shell with a visible raw cursor.
The helper needs POSIX sh, mktemp, cat, head, base64 and tr; unsupported hosts retain normal SSH
as the explicit bypass. Bootstrap scripts never include credentials or dump terminal output to logs.

Private OSC 9285 reports whether ssh is an executable rather than a shell alias/function, so
custom shell SSH behavior is preserved by bypassing interception. Private OSC markers: 9283 carries remote hostname (empty restores local context); 9284 carries
base64 NUL records `d<directory>`, `f<file>`, `c<command>`. Manifest at most 40,000 decoded bytes,
500 cwd entries, cached PATH output at most 20,000 bytes, up to 10,000 PATH entries scanned on
PATH change. Incomplete records are ignored. Current-directory candidates use the existing
history/path ranking engine. Child-directory/absolute/tilde remote completion is not implemented;
missing remote executables remain indeterminate instead of consulting the Mac filesystem.
Remote Git/link navigation is deferred; remote cwd is excluded from local Git reads and restoration
saves the original local directory. No remote agent or extra background SSH connection is needed.

## Phase checklist

- [x] Inspect local Warp diff lifecycle, limits and SSH bootstrap.
- [x] Reuse repo-root detection, shared layout and drawing geometry for the chip click.
- [x] Add right sidebar using shared opacity/background, stable PTY width transition.
- [x] Add requested one-pixel terminal borders against both visible sidebars.
- [x] Lazy file list, recycled native rows, bounded byte-indexed patches and large preview collapse.
- [x] Summary counts for index/worktree/untracked, binary labels and unusual literal paths.
- [x] Cancellable off-main reads with timeout, per-file stage/unstage including unborn HEAD.
- [x] Clear stale repository results and separate index mutation from view cancellation.
- [x] Reuse system SSH and shell integration without editing remote startup files.
- [x] Conservative detection/bypass rules; keep original command in block/history.
- [x] Remote prompt/status/cwd/hostname/PATH and bounded current-directory completion.
- [x] Keep remote paths away from local Git/completion/validation/restoration.
- [x] Cleanup/reset on exit and local prompt recovery after interrupted SSH.
- [x] Scratch Git fixture and local SSH transport fixture (no live SSH server).
- [x] Headless implementation handoff first, no headless runtime.
- [x] Backend/website ownership packages, contracts, schema/auth and release gates.
- [ ] Final full harness run, warning-free Debug/release, lint and SQL syntax check.
- [ ] Signed commit and build/install, without app launch.
- [ ] User verifies chip/pane switching/sidebar resize, large diffs and actual remote hosts/TUIs.

Actual SSH authentication/network reconnect/signal propagation and zsh/fish remote UX require
human/live-host testing; a transport fixture cannot establish those claims. Hunk staging/GitHub
reviews and remaining SSH parity have separate checklists in implementation-handoff.md.
