# Feature catalogue status — 2026-09-30, native R1

Source audit against `warp_features.md`, not old checklist ticks. The catalogue contains **33 named
features**, despite numbering up to 53. Substantially built means the main user behavior exists;
it does not claim identical Warp internals, every listed refinement, or exhaustive human acceptance.

**5 substantially built, 14 partial, 14 not implemented (including deferred/planned features).**
19/33 have at least some implementation. This is a feature count, not a percentage of engineering
work completed: search, persistence, media, remote control and Git review vary greatly in size.

| # | Feature | Status | Code evidence / remaining gap |
| --- | --- | --- | --- |
| 1 | Command blocks | Substantially built | Block/BlockGrid/HeaderGrid, shell boundaries, metadata and collapse; recent collapse/TUI fixes shipped |
| 2 | Decoupled editor | Partial | CommandEditorView: multiline, mouse, selection, native undo/redo; Vim modal editing absent |
| 3 | GPU rendering | Partial / native alternative | CoreText fixed-cell renderer and caches; Metal ChromaBloom effect exists, not Warp's full GPU glyph/atlas pipeline |
| 4 | Autosuggestions | Partial | Inline/history/local-path engine and popover; roughly 50 command specs, not 500+; no subshell completion generators |
| 5 | Shell integration | Partial | zsh/bash/fish OSC hooks, cwd/title/PATH/command boundaries; not full Warp DCS/environment metadata parity |
| 6 | Highlighting/validation | Partial, model only | ShellTokenizer and CommandResolver tested; editor does not consume them for syntax colors or diagnostic underlines |
| 7 | Context chips | Partial | cwd/branch/environment and clickable local diff totals; runtime versions, ahead/behind and complete chip actions remain |
| 8 | Block menu | Partial | copy/find/collapse/navigation; full copy formats, filter/bookmark/share menu scope incomplete |
| 9 | Block sharing | Partial, runtime | Native public static selection/redaction/preview/publish/revoke and website viewer; private live invitations and temporary public read-only streams; per-block menu refinements remain |
| 14 | Secret masking | Live deferred; export implemented | Common secret masking runs only on local static export preview; terminal/live content remains unchanged |
| 15 | Omnibar/palette | Not implemented | Fuzzy matcher exists separately; no unified palette UI/action search |
| 16 | Sidebar/tab manager | Partial | tabs/rename/reorder/pin/splits/resizing; foreground-process metadata, tab search and complete rich status/navigation absent |
| 18 | Restoration/recovery | Partial | SessionSnapshot JSON saves layout/directories at shutdown; no continuously persisted blocks or full crash recovery |
| 19 | SSH bootstrap | Partial | literal SSH bootstrap, zsh/bash/fish remote hooks, cwd/PATH completion and local-origin recovery; nested sessions and remote child-path completion remain |
| 20 | Notebooks | Not implemented | no native runbook/document feature |
| 23 | Kitty/iTerm2 images | Not implemented | no image protocol parser/cache/rendering |
| 24 | Themes/backgrounds | Partial | preset/custom palettes, editing/import/export, typography/opacity/blur; procedural background system absent |
| 25 | Launch configs | Not implemented | saved session layout is not reusable declarative launch configuration |
| 26 | Git review pane | Partial | local totals/chip, resizable sidebar/split, bounded unified diff and file staging; syntax/side-by-side/hunk staging/GitHub reviews remain |
| 27 | Local IPC daemon | Deferred | no daemon/socket/control CLI; retain catalogue deferral |
| 30 | Keymaps/navigation | Partial | configurable actions, panes/tabs/block navigation; Vim/Emacs modes and universal palette missing |
| 31 | Live sharing | Planned, no runtime | web-terminal viewing/control plan explicitly requested; full simultaneous multiplayer stays deferred |
| 32 | Alternate screen/TUIs | Substantially built | alternate grid, raw keys/mouse/paste, resize/cursor and edge-to-edge repairs |
| 33 | Hyperlinks/paths | Substantially built | OSC 8, path/link detection, hover and native open/navigation actions |
| 38 | Git root detection | Substantially built | RepoMetadata root walk and branch/project context |
| 39 | Word-block editor | Not implemented | tokenization exists but no interactive argument pills/reorder/delete UI |
| 41 | Headless frontend | Planned, no runtime | bounded H1–H4 implementation handoff; pure terminal core exists, no console frontend |
| 42 | Embedded ripgrep | Not implemented | current in-terminal Find is not indexed history/files/embedded rg search |
| 43 | Fuzzy matcher | Substantially built | pure FuzzyMatcher scoring/ranking and harness |
| 45 | Banners | Not implemented | no in-app contextual banner system; no announcement/network source yet |
| 47 | Process close safety | Not implemented | closure still shuts down coordinators without a central foreground-job confirmation policy |
| 48 | Undo closed pane/tab | Not implemented | editor undo is separate; no close-stack/restored historical output |
| 53 | Directory colors | Partial, model only | DirectoryColorTag table tested; no complete persisted picker/tab/chip color wiring |

## Next native priorities

1. Finish active-editor highlighting/validation and catalogue gaps: #6, Vim/Emacs scope, #39,
   directory tagging and chip/block/sidebar refinements. Keep increments small and measured.
2. Process close/quit safety (#47), local durable block/session checkpoints (#18), undo-close (#48).
3. Palette (#15) and file/history/scrollback search (#42).
4. Launch configs, remaining SSH/Git parity, media, notebooks and headless frontend (Phase 7).

Backend B1 identity, B2 relay/viewer, B3 owner-approved input, B4 grants and B5 public static sharing
are implemented. Temporary public viewing and a global Sharing disable switch were explicitly requested.
B6 measured scaling remains planned. See `roadmap.md`, `protocol.md` and `todo.md`.
No assistant/inference feature is planned. Local IPC, full multiplayer and live secret masking
remain separate deferred work unless explicitly requested.

## Previous startup repair

Build 108 fixes the build-107 startup recursion introduced in the Apple assistance cleanup.
Native editor tests now attach fields to a hidden window and cover editor reuse: 59 checks pass.
All 33 harnesses pass; Debug/release builds have no warnings; lint succeeds with existing unrelated
warnings. Installed app was opened with user authorization after collecting the crash report;
user confirmed it works. No further computer use is required. Broader feature UX remains subject
to user testing, as does the original per-phase acceptance policy.

R1 adds local Git review and conservative SSH bootstrap; see `native-review-ssh.md` for current
validation, limits, deliberate divergences and remaining human acceptance. Headless is handoff only.

Current native build: 115 installed unopened. All 35 native harnesses pass; Debug/release have
no compiler warnings. Current working tree passes 37 checks including the separately delegated C0
contract gates. Lint succeeds with existing/separately owned warnings. User acceptance is pending.

The counts at the top are the previous full catalogue audit. The public-sharing phase adds runtime
evidence for #9 and export-only masking for #14; see phase-public-sharing-todo.md for current gates.
