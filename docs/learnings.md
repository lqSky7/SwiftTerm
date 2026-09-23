# Learnings

Things that cost time to work out, kept so the next person (or agent) does not pay for them again.
Nothing here is a rule — the rules are in `AGENTS.md`. This is the residue of actually building it.

---

## Toolchain

- **`.macOS(.v26)` needs `swift-tools-version: 6.2`.** At 6.0 the manifest fails with
  `'v26' is unavailable` — the platform constant was introduced in `PackageDescription` 6.2.
  The machine is on macOS 27 / Xcode 27 / Swift 6.4, so `swiftc` targets `arm64-apple-macos26.0`.

## SwiftPM

- **One target can span `app/` and `crates/`** with `path: "."` plus an explicit `sources:` list of
  directories. That is what lets the tree stay Warp-shaped without a module boundary per crate.
- **`exclude` must come before `sources`** in the argument list, or the manifest is rejected.
- **Every `exclude` path must exist**, or SwiftPM warns on every build. `dist/` is kept alive with a
  `.gitkeep` for exactly this reason.
- **There is no glob in `exclude`.** The `index.md` in each of the fifteen directories has to be
  named individually. That is noise, but it doubles as the honest list of what is not code.
- **Non-Swift files inside a `sources:` directory are warnings**, not errors — `no rule to process
  file … of type 'file'`. Easy to mistake for a real problem.

## The test harnesses

- **There is no XCTest, and that shapes how a harness is written.** `swiftc` only allows top-level
  statements in a file named `main.swift`, so every harness opens with
  `@main enum SomethingTest { static func main() { … } }`.
- **A harness that touches `@MainActor` types must itself be `@MainActor`** — put the attribute on
  the enum, not just on `main()`, or every private helper in it loses the isolation.
- **A non-escaping closure parameter does not inherit the caller's isolation.** Passing
  `() -> Bool` into a `@MainActor` helper and calling it there fails to compile; passing the value
  to test instead of a closure sidesteps it entirely.
- **`-warnings-as-errors` in the runner is deliberate.** It is the only place the "zero new
  compiler warnings" gate is actually enforced, rather than hoped for.
- **macOS ships bash 3.2**, so no `mapfile` and no `ls --` in the runner.

## Swift

- **`"\r\n"` is one `Character`.** CRLF is a single extended grapheme cluster, so `"ls\r\n".hasSuffix("\n")`
  is **false** — the last character is CRLF, not LF. Anything that strips or scans line endings has to
  normalise `\r\n` to `\n` *first*; `replacingOccurrences(of: "\n", …)` will still find the LF *inside*
  the cluster, which is how this hides. It cost a real bug in `CommandSubmission.escaped`: a buffer
  ending in CRLF kept a line continuation with nothing after it.
- **A parameter cannot be labelled the same as its own name.** `func f(from from: Int)` is
  `error: extraneous duplicate parameter name`. Write `func f(_ from: Int)`.
- **`super.init(frame:)` traps in a subclass of an AppKit class whose designated initializer is
  something else.** `NSTextView`'s designated initializer is `init(frame:textContainer:)`; its
  `init(frame:)` is a convenience path that re-dispatches to `self.init(frame:textContainer:)`. A
  subclass that declares its own designated initializer gets an *unimplemented* stub emitted for the
  inherited one, so that re-dispatch lands on the stub and traps at launch:

  ```
  CommandEditorView.init(frame:textContainer:) + 32 [inlined]
  ... specialized CommandEditorView.init(font:palette:resolver:)
  ```

  Call the designated initializer on `super` instead — `super.init(frame: .zero, textContainer: nil)`
  — which skips the dispatch. `NSView.init(frame:)` *is* `NSView`'s designated initializer, so the
  same call is correct in `TerminalSurfaceView`; the trap is specific to the class whose real
  designated initializer has more parameters. It does not show up in a typecheck and only appears when
  the view is built.

## Overlays and focus

Two mistakes worth not repeating, both of which made Phase 3's editor unusable on the first build.

- **A view positioned from callbacks goes stale.** The editor's frame was computed in
  `sessionDidUpdate()` and `setFrameSize()` — so typing did not move it (the buffer changed, nothing
  recomputed), scrolling did not move it, and the document height it had reserved no longer matched.
  Fix: compute it in `draw`, from the same layout the renderer just painted, and have the buffer
  change set `needsDisplay`. Whatever moves the document then moves the overlay, because it is the
  same pass. This is the principle Warp's input follows — its element tree is laid out every frame
  from the model — and it is the only version of this that does not have a second thing to keep in
  sync.
- **Focus must be decided in one place, and never re-asserted on a timer or on output.** The first
  version gave the keyboard to the surface at launch, then handed it to the editor from
  `sessionDidUpdate()` — which fires on every chunk of shell output. So the first keystroke went to
  the pty, the echo came back, and *that* moved focus into the editor mid-keystroke. The user's words
  were "cursor focus moves away when I type", and every Enter after that was a bare newline to the
  shell, which is why the screen filled with prompts and no output. Fix: one property —
  `firstResponderView`, the editor while a prompt is showing and the surface otherwise — read by the
  window controller at launch and reconciled afterwards by a function that is a no-op when the two
  already agree.
- **Do not forward focus from `becomeFirstResponder`.** `makeFirstResponder:` sets the first responder
  *after* `becomeFirstResponder` returns, so a nested `makeFirstResponder:` inside it gets undone, and
  returning `false` to avoid that leaves the caller to decide what a refusal means. Ask the view which
  view should have the keyboard instead.

## The pseudo-terminal

- **`forkpty` is available from Swift and is the right call.** It is `openpty` + `fork` + `setsid` +
  `TIOCSCTTY` + `dup2` in one function, and the `TIOCSCTTY` is the part that matters: without a
  controlling terminal a shell cannot put a job in the foreground, so `Ctrl-C`, `Ctrl-Z` and `fg`
  all silently do nothing. `posix_spawn` cannot do this, because the `TIOCSCTTY` has to happen in
  the child between `fork` and `exec`.
- **A `read` parked on a pty master cannot be interrupted.** Not by a signal, not by cancelling the
  Swift `Task` around it. Closing the master is the only thing that unblocks it.
- **That makes shutdown order load-bearing.** The first version cancelled the read task and then
  signalled the shell; `finish()` then blocked the main actor in `waitpid` for a child that was
  never going to be signalled. It presented as a hung test harness. Signal the shell, close the
  master, *then* cancel — and poll `reapIfExited()` rather than blocking on the main actor.

## AppKit

- **`NSEvent.SpecialKey` is not what you would guess.** The real members are `.deleteForward`
  (forward delete), `.delete` (backspace), `.backTab`, `.carriageReturn`, `.enter`, `.begin`,
  `.f1`…`.f35`. There is **no `.escape`**.
- **Only some keys are "special".** Arrows, function keys, Home/End/PageUp/PageDown/Insert/
  DeleteForward arrive as `specialKey`; Tab, Return, Escape, Backspace and *every* Ctrl chord arrive
  as control characters in `characters`. Handling only `specialKey` means Ctrl-C never reaches the
  shell.
- **Shift-Tab arrives as the single control character `0x19`**, but every shell expects the two-byte
  `CSI Z`. It is the one key that has to be spelled out by hand.
- **`doCommand(by:)` needs `override`** — `NSResponder` already declares it. It is the hook that
  turns Option+Arrow into `ESC b` / `ESC f` via the input system's word-movement selectors.
- **`@preconcurrency` on an `NSTextInputClient` conformance** lets a `@MainActor` class satisfy the
  protocol's non-isolated requirements without `MainActor.assumeIsolated`, which the house rules
  ban. `NSTextInputClient` also needs `firstRect(forCharacterRange:)` or the IME candidate window
  lands in the corner of the screen.
- **`@Observable` works on a `@MainActor` class.** Mark non-`Sendable` stored properties
  `@ObservationIgnored` or the macro will try to observe an `NSView`.

## CoreText rendering

- **Measure the cell from a real glyph, not a typographic constant.** `CTFontGetAdvancesForGlyphs`
  on `M` is the only value that agrees with where the next column actually lands; several monospace
  faces disagree with `size(withAttributes:)`.
- **Snap the cell box to whole pixels, not whole points.** Rounding to points halves the usable
  density on a Retina display, which is where the crispness comes from.
- **An unflipped `NSView` is y-up**, so row *r* is drawn at `bounds.maxY - (r + 1) * cellHeight`.
  Flipping the view would make CoreText draw text upside down.
- **A glyph wider than one column must be its own `CTLine`.** A monospace face does not promise a
  double-width advance, so a run containing CJK drifts out of alignment from its start column.
- **Combining marks need folding, not placing.** `TerminalCell.displayWidth` returns 0 for them and
  the grid appends them to the cell before; a terminal that places them gets a row one column too
  wide.
- **`wcwidth` reads the process locale**, which a test harness must not have to mutate to ask how
  wide a character is. The East-Asian-Width table in `TerminalCell.swift` is hand-rolled for that
  reason.

## The bug worth writing down

The scrollback was never broken — 461 lines retained, the first line reachable at maximum scroll.
**The renderer was.** Its row cache was keyed by *view row* and compared a generation stamp, but a
history line carries no stamp of its own, so `generation` was `0` for every history line. The first
scroll step missed the cache and rebuilt correctly; every step after it hit, because `0 == 0`, and
redrew the previous viewport.

The symptom was not "scrolling is broken" — it was "scrolling doesn't feel like scrolling, it feels
like text re-rendering", plus "every scroll I can scroll less", because the frozen rows made the
viewport look like it had stopped moving. A cache whose invalidation key is not actually unique to
its contents fails exactly this way: plausibly, partially, and only under interaction.

Fixed by caching live screen rows keyed by *screen row* and rebuilding history rows each frame.
Also fixed the latent crash it was about to cause: a part-scrolled viewport asks for the row above
the top, and `line(at: -1)` indexed `scrollback[-1]` on an empty array.

**The lesson:** the harnesses cover the model and the parser thoroughly and the view not at all. A
wrong cache key lives entirely in the view. Anything with a cache needs its invalidation key
asserted, not assumed.

## The second one: a marker that means nothing

Phase 2's blocks were off by one in a way no unit test would have caught, because the unit tests all
started from `begin`.

The prompt cycle is not `A B C D`. zsh's first `precmd` reports the **exit status of the rc files**,
so the real stream from a fresh shell is:

```
A B D A B C D A B
```

`finish` sealed whatever block was last — which at that first `D` was the block about to hold the
user's first command. The block then looked sealed, so when the real `D` arrived `finish`'s guard
rejected it and the block kept `endLine` from the earlier, bogus marker. The block's range came out
`3..<3`: empty. Its header showed the right command and the right exit code, and its output was
nowhere.

**Two fixes, both guards rather than special cases.** `finish` requires the block to have been
submitted — a `D` with no `C` before it is the shell reporting on something that was never a
command. And `begin`'s reuse path requires the block to be neither submitted nor sealed.

**The lesson:** the end-to-end harness earned its place here. Every unit test passed while the
feature was broken, because the tests encoded the same wrong assumption as the code — that a
lifecycle starts with `begin`. A test that spawns the real shell and reads the real marker stream
does not share that assumption, and it found this on the first run. **A protocol is what the
protocol actually emits, not what its name suggests.** Capture the stream and read it before
trusting a state machine built on it.

## Environment

- **Launching the app from a sandboxed shell kills it when the command finishes.** It looks exactly
  like a crash — the process is gone seconds later, with no crash report and no output. Use
  `dangerouslyDisableSandbox` for an `open -a` smoke test, or you will spend an hour debugging a
  healthy app.
- **`swift build` cannot run under an agent's sandbox**, and it is not the project's fault. SwiftPM
  sandboxes manifest compilation itself, so it dies with `sandbox-exec: sandbox_apply: Operation not
  permitted`. `swift build --disable-sandbox` fixes *that* one and not the next one: `@Observable` is
  a macro, expanding it runs `swift-plugin-server`, and that needs `sandbox-exec` too — so the view
  layer stops with `external macro implementation type 'ObservationMacros.ObservableMacro' could not
  be found`. `run-tests.sh` and `lint.sh` are unaffected because they call `swiftc` directly and never
  compile the view layer, so a red `swift build` and a green suite are both true at once.
- **The whole app typechecks without SwiftPM**, which is the way around the above:
  `swiftc -typecheck -swift-version 6 $(find app/src crates -name '*.swift')`. It fails only on the
  macro; strip `@Observable` and `@ObservationIgnored` from a *copy* of the sources and it typechecks
  the view layer too, which catches every wrong name and signature without expanding a macro.
- **`git` cannot run in this directory.** Every git command creates a `*.lock` file and then unlinks
  it, and unlinking a `*.lock` path here is denied (`Operation not permitted`) even outside the
  sandbox — `git init` dies setting `core.repositoryformatversion`, `git add` dies writing the index.
  Keep a copy of the tree somewhere writable instead; that is the undo.
- **`sed` on `PATH` is a toybox shim, not BSD sed.** `sed -i '' -e …` fails with
  `sed: : No such file or directory`, because toybox reads `-i` differently. Use `perl -pi -e` in
  scripts, or the `Edit` tool.

## swiftlint

- `optional_data_string_conversion` rejects `String(decoding:as:)`; use
  `String(bytes:encoding:) ?? ""`.
- Warnings do not fail `lint.sh`, only errors do — so a warning left alone is a warning that ships.

---

## The buttons that "did nothing" were two different bugs, and neither was the titlebar

The report was *"clicking on the different buttons does absolutely nothing"*, and the first thing I did was
blame the window: with `.fullSizeContentView` the titlebar is still above the content, so I assumed its band
(~28pt) swallowed the clicks and moved every control out of it. **That was wrong.** The evidence was already
there — the same person reached the settings tab, which needs `⌘,` *or* the gear in the sidebar's header to
work — so controls in the top strip were clickable all along. The padding was reverted; the controls now sit
in line with the traffic lights, which is where they were wanted.

What was actually wrong, twice over:

1. **The material picker looked dead** because the opacity was multiplied into the material, so at 0% every
   material was invisible. See the next section — that is the real lesson.
2. **A tap gesture on a `Button` competes with the button's own.** `.onTapGesture(count: 2)` is not "the
   double-click *in addition to* the click"; the two are arbitrated and a single click can be lost.
   `.simultaneousGesture(TapGesture(count: 2))` is the spelling that means what it looks like it means.

One thing from that detour is worth keeping, because it costs one line and removes a whole class of failure:

```swift
VisualEffectView(...).allowsHitTesting(false)
SidebarBackground(...).allowsHitTesting(false)
```

A full-window background layer that takes hit tests is a window where nothing responds, and `Rectangle()`
and `NSVisualEffectView` both take them by default. Saying so explicitly is cheaper than being sure about
z-order.

**The lesson is not "check the titlebar".** It is that a confident diagnosis of a view bug, made without
running the view, is worth about as much as no diagnosis — and that a fix based on one should be cheap to
revert. This one was three numbers.

---

## "Window opacity" is not "the opacity of the material"


The first version of the chrome's opacity control multiplied the material layer by the value:

```swift
SidebarBackground(material: ...).opacity(chrome.sidebarOpacity)   // wrong
```

At 0 that is nothing at all, whatever the material — so the material picker appeared to do nothing, and
the report was exactly that: *"the settings options only work when opacity is not zero."* The control was
doing what it said and the saying was wrong.

The arrangement that works, and that `vicinae` uses (`src/server/src/config/config.hpp`, and
`extra/config.jsonc`: *"Needs window opacity < 1 to be visible"*), is two stacked layers:

```
material        ← always drawn
windowBackground.opacity(windowOpacity)   ← drawn over it
```

So the opacity is how much of the window's *own background colour* covers the material. At 1 the material
is hidden; at 0 only the material is left. Two consequences worth keeping:

- **The material is meaningful at every opacity**, which is the whole point.
- **Picking a material has to set an opacity that shows it.** vicinae keeps a per-material default
  (`TRANSLUCENT_OPACITY = 0.6` for glass, `BLUR_OPACITY = 0.55` for blur) and uses it when the user has not
  chosen one. Ours does the same, and moves to it on selection — a material that arrives behind an opaque
  window is a material nobody can see they picked.

One more thing from the same file, worth knowing before adding a hover or a selected-row fill: vicinae
lifts the opacity of *fills that carry meaning* rather than letting them share the window's alpha —
`base + (1 - base)² × 0.65` — because "selection, hover and grid tiles fade toward invisibility" at low
opacity. Ours does not need the lift, because the selection fill here is not derived from the window
opacity at all; but a white-lift fill (which is what this had) is invisible the moment the window
background is opaque white, so the selection is `Theme.Colors.ramp` instead — a little black on light, a
little white on dark, which reads on the background at any opacity and on the material behind it.

---

## A material needs a transparent window, and `NSVisualEffectView` is the only thing that made one

The report was *"only thin one actually lets background content through. both glass ones feel opaque"* —
and the shape of that clue is the whole diagnosis. Two of five materials worked, and the two that worked
were the ones that contained an `NSVisualEffectView`.

`NSVisualEffectView` with `.blendingMode = .behindWindow` does two things, and only one of them is
obvious. It blurs what is behind the window — and it makes AppKit render *its own region* of the window
translucently. The second one is a side effect nobody documents, which is why the window had never needed
`isOpaque = false`: there was always a `VisualEffectView(.underWindowBackground)` filling it, and that was
what made the window see-through.

So when the backdrop layer was removed — correctly, because the material *is* the window's background —
the window went back to being opaque, and everything that is not an `NSVisualEffectView` started sampling
the window instead of the desktop:

```swift
window.isOpaque = false
window.backgroundColor = .clear
```

Two lines, in `TerminalWindowController.init`. SwiftUI's `.glassEffect` refracts whatever is behind the
window and does not punch that hole for itself, so without these it refracts the window's own background —
which is what "feels opaque" was.

The general lesson: **an effect that samples the backdrop needs a backdrop to sample**, and "the window is
transparent" is not a property of a view. It is a property of the window, and a view that used to make it
true by accident is a load-bearing view.
