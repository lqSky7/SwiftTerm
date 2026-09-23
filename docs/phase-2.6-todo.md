# Phase 2.6 — Reflow — Todo

The working checklist for Phase 2.6. Ticked against a real run.

The plan is the phase entry in `phases.md`; this is the record of building it.

## The defect

Phase 1 planned `TerminalLine` as "cells + soft-wrap flag" and ticked it. The flag was built and never
used, so `TerminalGrid.resize` narrowed or padded each line instead of re-wrapping: **narrowing the
window destroyed the right-hand side of every long line, for good, and widening filled the space with
blanks rather than giving it back.** Three later documents described the reflow as working, which is
what kept it invisible for five phases.

## The work — `crates/warp_terminal/src/model/`
- [x] `put` marks the row wrapped at the two places a wrap actually happens, before the `lineFeed` that
      follows it, because that feed may scroll and the flag has to ride into history with its line
- [x] `TerminalGrid.reflow` — a logical line is rejoined, re-split at the new width, and its flags rebuilt
- [x] `reflow` takes history and screen **together**, because a logical line can straddle the boundary
- [x] The cursor's line and column are mapped through the reflow, so it lands on the same character
- [x] The screen keeps the *bottom* of the result when the content is taller than it, and the padding
      goes **below** the content when it is shorter
- [x] The screen's trailing blank rows are dropped before reflowing and never past the cursor's line —
      they are padding, and counting them as content pushes real output into history
- [x] `keepsHistory: false` on the alternate screen, which has no history by definition
- [x] The saved primary screen is re-wrapped too, or leaving a full-screen program after a resize puts a
      screen of the old shape back
- [x] `TerminalLine.resize` is gone: nothing narrows a line any more, it re-wraps

## Gates
- [x] `Tests/terminal-grid-test.swift` — 106 checks, 38 of them new for the reflow
- [x] The content invariant: the logical text is identical at every width, asserted at 12, 40, 7, 30
      and 3 columns
- [x] `./Scripts/run-tests.sh` passes 100% — 13 harnesses, 514 checks
- [ ] `swift build -c release` clean with zero warnings — **not verified here**, as always
- [x] `./Scripts/lint.sh` passes
- [x] Pure-model grep returns zero files
- [x] `index.md` updated in every directory that changed
- [ ] Installed and running — **not run**

## Three things the harness caught that reading the code did not

Each of these was written confidently and was wrong, and each would have shipped:

1. **Padding above the content.** The first version padded the screen at the top, matching the old
   `resize`. That puts blank rows *over* the prompt — and worse, `contentLineCount` scans from the end
   for blanks, so leading blanks count as content and every block would have drawn a gap above itself.
   The old code had this bug too; the harness's `resize` test had been asserting the buggy behaviour as
   correct, so the fix showed up as three failing checks in a test written before this phase.
2. **Padding counted as content.** Re-wrapping the screen's trailing blank rows inflated the result by a
   row per blank, and the extra rows pushed real content off the top into history — a reflow that looks
   like it worked while quietly losing the beginning of a line. Found by a check asserting that a
   six-column reflow of a twelve-character line leaves nothing in history.
3. **A test that proved the wrong thing.** The content invariant was first written as rows joined by
   newlines, which changes whenever the wrapping changes — so it failed on correct behaviour. It had to
   become *logical* text: rows joined, with a newline only where a row is not a continuation. And a
   wrapped row's trailing blanks are load-bearing, because the wrap happened at the last column, so a
   space there is a space the user typed. Trimming it lost a character at every wrap.

That third one is the same lesson as `learnings.md`'s Phase 2 note and the Phase 1 tick: **a test
written from the same belief as the code proves the belief, not the behaviour.**
