# src/shared_session — the browser viewer

The viewer half of live terminal sharing. It renders what the Mac publishes; it never parses an
escape sequence and it never runs a terminal.

| File | Holds |
| --- | --- |
| `state.ts` | the reducer — one epoch, contiguous sequences, and the resulting state re-validated |
| `connection.ts` | the socket — ticket, frame validation, snapshot assembly, resume, backoff, control |
| `keys.ts` | a keystroke → the contract's input union, as a pure function |
| `render.ts` | the canvas — cells, wide-cell arithmetic, cursor |
| `palette.ts` | the standard 256-colour palette and the eight style bits |
| `viewer.tsx` | the React surface — blocks, status, focus, local copy, the control affordance |

## The three rules this directory exists to hold

**Cells are pixels; words are text.** A grid is drawn on a canvas. A block's command, its exit code
and every status line are React text nodes. Terminal content therefore reaches the page in exactly
two ways, and neither of them is `innerHTML` — a command containing `<script>` is a row of glyphs.
The reducer does not sanitise and does not pretend to: it stores the string, and the page keeps it
inert.

**The contract is the authority, not the relay.** Every inbound frame is validated with
`validateFrame(value, "relay_to_viewer")` before anything looks at it, and a frame this build cannot
accept closes the socket rather than being guessed at. The relay forwards bytes; it is not trusted
to have checked them.

**Nothing is adopted before it is verified.** A snapshot is reassembled by the contract's
`SnapshotAssembler` with a Web Crypto digest, and a damage frame is applied to a copy and the result
run through `validateSnapshot` before it replaces what is on screen. The reducer's op-for-op
behaviour mirrors `crates/shared_session/src/WireStreamState.swift`; the golden fixture test is what
keeps the two honest.

## The palette decision

The contract ships no palette table — a style carries either an explicit RGB triple or an index into
the standard 256-colour palette — so `palette.ts` builds the standard xterm table. The alternative
would be for the viewer to invent a theme, and then the same stream would render differently on two
machines. B2B's encoder is the other half of that agreement.

The style flags are the eight bits the contract names, in its order: bold, dim, italic, underline,
blink, inverse, hidden, strike. A renderer reads the bit; it never maps one to a font name or a CSS
class, because the host has no way to know what those would be.

## Asking for control, and typing with it

Reading is not a privilege — copy, focus and scroll work with no lease at all — and typing is.
`control.ts` is not a file: the state lives on `ViewerConnection` as `ControlState`, deliberately
*outside* `ViewerState`. That reducer mirrors `WireStreamState.swift` operation for operation and its
parity is worth keeping, so control — a separate question with a separate lifetime — is kept out of it
rather than folded in.

Four rules, each a failure with a name:

- **A sequence is advanced before the frame is sent and never reused.** The contract says a sequence is
  next-only, and that a transport loss leaves every unacked input uncertain and not to be retried.
  Re-sending is answered as a duplicate at best and as a gap at worst, and a gap means the two ends
  disagree about what was typed.
- **A gap ends the lease.** The browser drops to `none` and says so, because no amount of retrying
  closes a disagreement about what was typed. Asking again is the only recovery, and it is the
  person's to make.
- **The lease ends when the connection does.** The relay binds it to the socket and forgets it when
  that socket closes, so a browser that kept showing control would be showing something it no longer
  has — and every keystroke would come back as a stale lease.
- **A new generation ends it too.** A host that reconnected is a new epoch, and the contract says a
  lease does not survive into one. Keeping it would leave the browser typing under a generation that
  has ended.

`keys.ts` is where a keystroke becomes an operation, and it is a pure function over a plain object so
it can be tested without a browser. Two decisions in it are worth knowing: a **letter is identified by
`code`, not by `key`** — `⌥a` on a Mac reports `key: "å"`, and reading the letter off that would be
the keyboard-layout guess the contract forbids — and **Command is the browser's** while Control is
forwarded, because Ctrl-C must stay an interrupt and nobody should lose `⌘C` on a page they are
watching.

The input itself is a real `<textarea>`, not a focus trap on the blocks. Composed text — an IME
candidate, a dead key — arrives as an `input` event, and the contract's `text` operation is defined as
exactly that. Named keys and chords arrive as `keydown` and never produce an `input` event, so the two
paths cannot double-send. The value is cleared on every event and never read back: a funnel, not a
buffer.

## Why the contract is imported from outside this package

`website/` consumes `../contracts/ts/wire.ts` directly rather than a copy. One contract for the
relay, the tests and the browser means a rule cannot be fixed in one place and left broken in
another. That needs two settings: `turbopack.root` in `next.config.ts`, because the bundler refuses
to reach above its project root by default, and `allowImportingTsExtensions` in `tsconfig.json`,
because Node's ESM resolver does no extension guessing — which is also why every relative import in
the `.ts` modules here names its file.

## Where to look first

`state.ts` for what a frame means, `connection.ts` for the state machine, `palette.ts` for the one
thing the contract leaves open.

Socket URLs preserve the API proxy prefix. The viewer resolves `/api` against its own browser origin.
