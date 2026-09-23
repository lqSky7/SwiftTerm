# Audit — Phase 1 and Phase 2

Phase 1 and Phase 2 were built by a different agent, and the audit that produced `phases.md` Phase 2.6
found one ticked box that was never true. So the same question was asked of every other ticked box in
those two phases: **is this actually implemented, and is it implemented completely?**

A box is a lie if the data structure exists but nothing uses it, if the code path is unreachable, if a
document contradicts the code, or if the feature only works in the case the author happened to try.
Divergences from Warp are a separate question, and the project's own rule is that a divergence is
allowed only where a phase doc records it and why.

Findings are ranked by severity: a defect that loses a user's output ranks above a cosmetic difference.

---

## Fixed in the audit's own commit

| # | Finding | Where |
| --- | --- | --- |
| 1 | **Bracketed paste never turned on.** `TerminalModes.apply` had no `case 2004`, so `CSI ? 2004 h` was dropped and `bracketedPaste` could never become true. The paste path read it, and a comment claimed the wrapper was "the only thing standing between a pasted script and running every line of it" — a claim about protection that did not exist. A pasted multi-line script ran line by line. | `TerminalModes.swift` |
| 2 | **`DECSCUSR 0` stopped the cursor blinking.** `blinks = parameter % 2 == 1` reads 0 as steady, but 0 means "the default", and the default blinks. | `TerminalCursorStyle.swift` |
| 3 | **The selection tint stopped at the content.** A selected block was tinted from `contentTop` down, so the header — the command that ran — was left out, and the tint said half the block was selected. It spans `headerTop` now. | `TerminalRenderer.swift` |
| 4 | **A second stray temp file.** `Tests/XXKYdONm` was an earlier copy of `completion-test.swift`. Not a build warning — `Tests/` is outside the target — but cruft of the same class as `XXoWyLMh`, and the sweep for others came back empty. | moved to `backup/swiftTerm-stray/` |

## Open, with the fix

| # | Finding | Severity | Fix |
| --- | --- | --- | --- |
| 5 | **bash users lose their entire configuration.** `ShellBootstrap` launches `bash --rcfile <generated>/integration.bash -i`, and the generated file sources nothing. zsh gets all four of its dotfiles shimmed; bash gets neither `~/.bashrc` nor `~/.bash_profile`, and `phase-1.md` explicitly requires the generated rc to "source the user's own dotfiles first". Aliases, `PATH` additions and prompt settings all vanish. | **High** | Source the user's rc from the generated one, as Warp's bash bootstrap does |
| 6 | **Scrolling back and then new output yanks the view.** `sessionDidUpdate` keeps `scrollPosition` unchanged while `viewportTop` is derived from `totalHeight`, so every new line moves the viewport down by a line and the text being read scrolls away. The comment above it claims the opposite. | **High** | Add the document's growth to `scrollPosition` whenever it is non-zero |
| 7 | **A wide glyph is not drawn as its own run.** `phase-1-todo.md` ticks "wide glyphs as their own runs, so the columns stay aligned", and the code builds the runs — then concatenates them all into one `CTLine` and draws it at one origin, so the run boundaries reposition nothing and a CJK line drifts out of alignment. The file's own comment says a monospace face does not promise a double-width advance. | Medium | Draw one `CTLine` per run at `originX + column * cellWidth` |
| 8 | **`OSC 52` is unimplemented.** `TerminalEvent.clipboardWrite` is declared and never emitted, and `phase-1.md` lists it. | Medium | One `case "52"` in `handleOSC` |
| 9 | **Three parsed modes are stored and never read.** `reverseVideo` (DECSCNM), `focusReporting` (`?1004`, which would send `\e[I`/`\e[O` on focus change) and `applicationKeypad` (DECKPAM/DECKPNM, which never reaches the key table). None is recorded as deferred anywhere. | Medium | Wire each, or record them as deferred |
| 10 | **The reflow.** `isWrapped` was only ever set false and `TerminalLine.resize` truncated. This is the one the audit was prompted by. | **High** | **Fixed — `phases.md` Phase 2.6** |
| 11 | **A document contradicts a constant.** `phase-2.md` says the OSC payload is capped at 8 KB; `VTParser` caps it at 64 KB. | Low | Correct whichever is meant |
| 12 | **Stale ticks and a stale index.** `phase-2-todo.md` still ticks five things the 2.5 rework deleted (`BlockList.shift(by:)`, `trimmedLineCount`, `begin`'s reuse path, `Block` as a line range, and the renumbering), and its preamble says `evictOldest` was cut as "a second policy" while `BlockList` calls it. `app/src/terminal/view/index.md` describes a selection *border* and a *parked editor* as though both were live. | Low | Correct the docs |

## Could not be verified from the code

Recorded rather than guessed at:

- Every gate tick in both checklists — there is no usable Swift toolchain in the audit's environment, so
  `swift build`, `run-tests.sh` and `lint.sh` were not re-run.
- Harness counts have drifted across documents (55→68, 71→68, 25→38, 39→41); the run is the truth.
- Whether fish's `-C` runs before or after `config.fish`.
- Whether `URL(string:)` rejects a `$PWD` containing `#` or `?` — `OSC 7` is not percent-encoded.
- Whether AppKit really delivers `moveWordLeft:` / `deleteWordBackward:` for Option+arrow, which is what
  makes "Option as meta" more than the three bindings `doCommand(by:)` happens to implement.
- Everything in the view layer: no harness compiles `app/src/terminal/view/`, so findings 6 and 7 are
  read rather than run. That is the same gap `learnings.md` names.

## What this audit says about the two phases

The parser, the grid and the session hold up well: the escape-sequence vocabulary is broad, the
alternate screen and the scroll region behave, and the harnesses covering them are real. What the audit
found is concentrated in two places — **modes that are parsed and then never consulted**, and
**documentation that outran the code**. Both are the same failure as the `isWrapped` tick: a claim about
the system that was never checked against the system.
