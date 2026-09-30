# website/src/app — index

| Route | Holds |
| --- | --- |
| `/` | the landing page; the hero terminal frame is drawn in markup so it stays in the token set |
| `/sign-in` | email and password against Supabase Auth, then the token exchange |
| `/account` | the signed-in account, its devices, and revocation |
| `globals.css` | the token set, copied verbatim from aside-clone |

## The divergence to remember

The handoff specifies authorization code + PKCE through a backend callback. **This Supabase project
has no OAuth provider configured**, so there is no redirect target. The working path is: Supabase
issues an access token, and the site exchanges it at `POST /auth/session`, where the backend verifies
the signature against the issuer's JWKS.

That is not a bypass — the backend still verifies the signature and still creates the account from
the verified subject, never from anything the client claims. It is also not a dead end: the exchange
endpoint is the same one a redirect callback would use, so adding a provider later changes only
*where the token comes from*, not what validates it.

## What is deliberately absent

There is no live viewer here yet. When B2C adds one, these rules from the handoff apply and are not
negotiable:

- The grid is drawn on a canvas; block, header and error text go through DOM `textContent`.
- No `innerHTML`, no OSC execution, no terminal subprocess, no second VT parser.
- Reuse `contracts/ts/wire.ts` for validation and `SnapshotAssembler` for reassembly. It is
  dependency-free and browser-safe, and `SnapshotAssembler.finish` takes an **injected** digest
  because the only browser SHA-256 is `crypto.subtle` and it is asynchronous.
- The browser never resizes the host PTY. It fits and scrolls the geometry the publisher sent.
