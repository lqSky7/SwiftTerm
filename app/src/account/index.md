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

## Still to add

The sign-in **flow** — `ASWebAuthenticationSession` against the OIDC provider, the nonce, and the
`swiftterm://auth/callback` URL this app now registers. `AccountController.signIn` takes an access
token and is what that flow calls once it has one; the flow itself is the next piece of B1B.
