# contracts/fixtures — index

The shared fixtures. Swift writes them; both Swift and TypeScript read them. They are the only
thing that makes "the two implementations agree" a test rather than an assumption.

| Path | Holds |
| --- | --- |
| `golden/snapshot-blocks.json` | a canonical blocks-mode snapshot: wide glyphs, a combining sequence, an emoji ZWJ sequence, an empty grid, a collapsed block, a non-default style |
| `golden/snapshot-fullscreen.json` | the same document in fullscreen mode |
| `golden/share.json` | a canonical static export with style spans |
| `golden/SHA256SUMS` | the SHA-256 of each golden, as recorded by the Swift harness |
| `invalid.json` | the cases both implementations must reject, each with the allowlisted code it must be rejected with |

## Why the goldens are checked in rather than generated at test time

A generated fixture cannot catch a change, because it is regenerated to match. A checked-in one
turns any change to the wire bytes into a visible diff, and the harness refuses to update it
unless `--write-fixtures` is passed explicitly. Regenerating is a deliberate act with a diff to
read, not a side effect of running the tests.

`invalid.json` is checked in for the same reason. If a rule silently stops being enforced, the
index does not change — so the diff shows up on the side that stopped enforcing it, not as a
quietly shrinking test.
