# src/shared_session — the browser viewer

The viewer half of live terminal sharing. It renders what the Mac publishes; it never parses an
escape sequence and it never runs a terminal.

| File | Holds |
| --- | --- |
| `state.ts` | the reducer — one epoch, contiguous sequences, and the resulting state re-validated |
| `connection.ts` | the socket — ticket, frame validation, snapshot assembly, resume, backoff |
| `render.ts` | the canvas — cells, wide-cell arithmetic, cursor |
| `palette.ts` | the standard 256-colour palette and the eight style bits |
| `viewer.tsx` | the React surface — blocks, status, focus, local copy |

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
