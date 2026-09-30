# app/src/account — index

The account, as the window sees it. One file, and it is deliberately the only place the app talks to
the cloud.

| | |
| --- | --- |
| `AccountController.swift` | `@MainActor @Observable` — sign-in state, the device list, and every cloud call |

## Two rules, and both are structural

**Signed out means no cloud work at all.** The controller is created eagerly by `AppCore` and does
nothing until `signIn` is called: no timer, no socket, no request, no retry. That is the handoff's
"offline terminal with zero cloud work", and it is a property of the structure rather than of a flag
somebody remembers to check — there is no code path that runs on its own.

**Cloud state never reaches terminal state.** Sign-out clears the account, the cookie jar and the
device registration. It does not touch a pane, a block, a scroll position or a shell. A person
signing out of a website should not lose the terminal they are reading, and the way that stays true
is that this type holds no reference to anything in the terminal layer.

## Cancellation is the point of the task

`signIn` holds its `Task` and cancels the previous one before starting. Every reason matters:

- a person who closes the sheet mid-flight must not have a session appear afterwards;
- a second attempt must supersede the first rather than race it;
- a sign-out during a sign-in has to win.

`CloudError.cancelled` exists so that a cancellation is never reported as a failure. Folding it into
`offline` would tell someone their network is broken when they pressed Cancel.

## Sign-out and revoke are different acts

Sign-out ends the **session** and keeps the device credential: the credential is this installation's
secret, and it is what lets a later sign-in find the same device rather than registering a second
one. `revokeDevice` is what ends the credential's *authority*, and it is explicit.

## Configuration

`CloudConfiguration.fromBundle()` reads `SwiftTermAPIBaseURL` and `SwiftTermAPIOrigin` from
`Info.plist`, falling back to the deployed pair when either is missing or unparseable. That is how a
debug build points at a local backend without editing code.

The `Origin` is sent on every write because the backend refuses a cookie-authenticated write whose
`Origin` is missing or not on its allowlist. That rule was written for browsers, where a cookie is
ambient; a native client is not subject to that threat but does have to satisfy the rule. It is a
wart in the contract, recorded in `docs/backend/todo.md` rather than hidden here.

## Sign-in

`SignInFlow.swift` drives it: a password grant against Supabase Auth, then the exchange at
`POST /auth/session` that turns the token into a session the backend knows.

**The Supabase project has no OAuth provider configured**, so there is no authorization endpoint to
send a browser to and no redirect to come back from — the same divergence `website/src/auth/client.ts`
records. That is why this is a password grant and not an `ASWebAuthenticationSession` flow. The
exchange endpoint is the one a redirect callback would use, so configuring a provider later changes
this file and nothing else. The `swiftterm://` scheme is registered in `Info.plist` ahead of that.

The **refresh token is stored before the session is created**, not after: a session that exists but
cannot be renewed is a session that expires mid-stream with no way back. Renewal is not on a timer —
the token is good for an hour and the app has no reason to hold a wake-up for that — it runs when the
backend says the session has ended, which is the moment it is worth attempting.

Every rejected credential gets **one** answer. Telling "no such account" apart from "wrong password"
is how an account-enumeration oracle gets built, and the website makes the same choice.

## Still to add

The **account UI** — an AppKit surface for signing in, the device list and revoke. `AccountController`
and `SignInFlow` are complete enough to drive it; nothing renders them yet.
