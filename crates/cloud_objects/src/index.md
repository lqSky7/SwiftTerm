# cloud_objects/src — index

The export contract sources, and the client that talks to the backend. Foundation-only, same rule as
`crates/shared_session/src` — and enforced rather than asserted: the `cloud-objects-test` harness
compiles this directory without the view layer, so a file that reached for AppKit stops it compiling.

| File | Holds |
| --- | --- |
| `WireShare.swift` | the export document and the capability rules |
| `CloudError.swift` | every way a cloud call can fail, as a closed set |
| `CloudCredentials.swift` | the device credential, and where a secret lives |
| `CloudAPI.swift` | the route table, the response types, and the HTTP client |

## `WireShare.swift`

`WireShare.swift` holds the export document and the capability rules. Two of them are worth
knowing before editing:

- A span is in UTF-16 offsets — the offsets a browser string actually uses — and spans must be
  ordered, non-overlapping, non-zero-length and inside the line.
- The directory is a display label the owner approved in the native preview. An absolute path, a
  `~` path or a `..` component is refused rather than abbreviated, because quietly turning a real
  path into a label is the implicit export the contract forbids.

The share capability is 32 random bytes in one canonical base64url spelling. The server stores
only the SHA-256, and the secret lives in the browser fragment.

Exports enforce sealed blocks, bounded native values and UTF-16 span boundaries before upload.

## The cloud client

**Routes are data.** `CloudRoutes` turns arguments into a `CloudRequest` — method, path, body, and
whether CSRF applies — and `CloudAPI` only knows how to send one. That split is what makes the API's
shape testable without a network, and it is where a path change would otherwise rot silently.

**Failures are a closed set.** The backend answers a refusal with an allowlisted code and never with
a message, so the client does the same: `CloudError` switches on the code and produces a sentence
from a table, and an unknown code becomes the generic sentence rather than being shown. Cancellation
is its own case rather than a flavour of `offline` — reporting someone's Cancel press as a network
problem is the failure that separation exists to prevent.

**The device credential is random, 256 bits, generated once.** Not derived from the hostname or a
hardware id: a credential derived from the machine is one a second machine can guess and one that
changes when the hardware does. It lives in the Keychain under
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so it does not roam and does not ride a backup.

**The `Origin` header on writes is a wart.** The backend refuses a cookie-authenticated write whose
`Origin` is missing or is not on its allowlist — a rule written for browsers, where a cookie is
ambient and a forged request is the threat. A native client is not subject to that threat, but it
does have to satisfy the rule, so it declares the website's origin. Recorded in
`docs/backend/todo.md` rather than hidden in the client.

## Where to look first

`CloudAPI.swift` for the routes and the client, `CloudCredentials.swift` for the credential,
`CloudError.swift` for what a failure means. The account model that uses all three is
`app/src/account/`.

CloudCredentials.swift stores per-account device credentials and persistent registration request IDs for lost-response retries.

CloudAPI retains URLSessionConfiguration.ephemeral’s built-in cookie store; constructing HTTPCookieStorage directly discarded authentication cookies on this Mac.

CloudRoutes.invite and CloudInvitation carry recipient-bound live-stream invitations; the account layer validates recipient UUID and permission before sending.
