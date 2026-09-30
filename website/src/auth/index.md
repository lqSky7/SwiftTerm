# website/src/auth — index

| File | Holds |
| --- | --- |
| `client.ts` | sign-in, sign-out, the account, and the device list |

## What this directory is not

It is not an authentication implementation. Every decision that matters is made by the backend:
issuer and audience are verified there, the session secret is generated and hashed there, and the
CSRF digest is compared there. This directory holds a cookie the browser cannot read and a token it
must echo back — nothing that would be a credential if it leaked.

## The sign-in flow, and why it looks like this

The handoff describes authorization code + PKCE with a backend callback. This Supabase project has
**no OAuth provider configured**, so there is no redirect target to send a browser to. The flow here
is therefore:

1. The site authenticates against Supabase Auth and receives an access token.
2. It posts that token to `POST /auth/session`.
3. The backend verifies the signature against the issuer's JWKS, maps `(issuer, subject)` to an
   account, and sets a session cookie.

Step 3 is the same code a redirect callback would call. Adding a provider later changes step 1 only.

When Supabase is not configured for a deployment, the sign-in page falls back to accepting a pasted
access token. That is not a bypass: the backend still verifies it, and it exists so the exchange can
be exercised before an email template or a provider is set up.

## A deliberate non-distinction

`signInWithPassword` does not separate "no such account" from "wrong password". That distinction is
how an account-enumeration oracle gets built, so both produce the same message.
