# website/src/components — index

| File | Holds |
| --- | --- |
| `navbar.tsx` | the chrome: mark, centred links, account control |
| `logo.tsx` | the SwiftTerm mark |

## The mark is monochrome on purpose

Every path in `logo.tsx` inherits `currentColor`. There is no accent fill, and adding one would put
the only saturated pixel in the product into the chrome. The shape is a prompt — a chevron and a
cursor block inside a rounded frame — because that is what a terminal is made of.

## The navbar does not flash

The account control renders nothing until the session check settles. Rendering "Sign in" first and
swapping it for the account name would show every signed-in visitor a moment of being signed out.
