# B1B completion — sign-in path and native account

This phase ends with build/install and human testing. B5A static export is the next phase.

- [x] Inspect actual source, phase scope, Swift architecture and deployment configuration.
- [x] Verify supplied SSH key and production service availability.
- [x] Preserve pre-existing backend logging diff; no backend code deployment required.
- [x] Verify existing zrok health endpoint with GET (HEAD is not supported).
- [x] Trace browser API base, session cookies, CSRF cookie reads and socket URL derivation.
- [x] Add fixed-upstream Cloudflare proxy under website `/api/*`.
- [x] Keep assets on the current static Next.js export deployment.
- [x] Preserve Origin, cookies, CSRF and WebSocket headers; refuse automatic redirects.
- [x] Retain `/api` prefix when deriving browser socket URLs.
- [x] Default browser API to its website origin; retain explicit local-development override.
- [x] Add proxy regression checks and update socket path expectations.
- [x] Pass website typecheck, 65 tests and production build.
- [x] Deploy website and verify production API health and auth refusals.
- [x] Verify actual same-origin WebSocket upgrade and selected subprotocol.
- [x] Query project settings before offering native anonymous sign-in.
- [x] Request anonymous grants and store the refresh credential in Keychain.
- [x] Explain anonymous account recovery limitation before signing in.
- [x] Own/cancel issuer authentication and backend exchange tasks.
- [x] Restore refresh credential only on explicit Account/Share opening.
- [x] Clear refresh credential on sign-out and keep local shells intact.
- [x] Add native grouped Account window accessible from Settings and Share.
- [x] Show cloud identity separately from the local OS profile.
- [x] Show devices, refresh, register and revocation confirmation.
- [x] Stop native sharing before current-device revocation.
- [x] Clear cached device ID at sign-out and scope secrets per cloud account.
- [x] Keep registration request ID stable across lost-response retries.
- [x] Rotate revoked credential/request ID without rotating on network lookup failures.
- [x] Guard device results against cancellation and account changes.
- [x] Add issuer-response/offline/cancellation tests and device identity isolation/retry tests.
- [x] Repair missing remote-input sources in the collapse/undo harness lists.
- [x] Reproduce Mac sign-in 201 followed by /me 401 using Foundation-only HTTP probe.
- [x] Preserve URLSession's built-in ephemeral cookie jar; verify /me 200 and logout 204.
- [x] Reproduce browser user-agent receiving zrok HTML instead of API JSON.
- [x] Add documented skip_zrok_interstitial header on Worker upstream requests.
- [x] Verify browser user-agent end-to-end sign-in after redeployment (201 / 200 / 204).
- [x] Pass complete native harness suite after final edits (40 Swift harnesses + contract gate).
- [x] Run lint and build/install final release without launching (build 132, zero compiler warnings).
- [x] Update affected directory indexes and record proxy architecture divergence.
- [x] Commit all phase work with git -s -S (implementation: 1bd3dbf).
- [ ] Human tests password/anonymous sign-in, relaunch recovery, account devices and live sharing.

The proxy is a recorded deployment change from browser-to-zrok traffic: browser cookies and CSRF
must share the website origin, and a browser/domain blocker must not prevent access to the API.
The Worker uses Cloudflare's native fetch proxy and ASSETS binding; no extra proxy framework.
Auth provider/PKCE migration and native static export remain outside this phase.

Human-reported failures resolved in this phase: custom HTTPCookieStorage() discarded native session
cookies; retaining the default ephemeral store passed the shipped CloudAPI live exchange, /me and
CSRF logout. Browser User-Agent received zrok's HTML interstitial through the Worker; setting its
documented skip_zrok_interstitial header passed browser-UA exchange 201, /me 200 and logout 204.
No computer-use validation was performed. Official references:
https://developer.apple.com/documentation/foundation/urlsessionconfiguration/httpcookiestorage
https://netfoundry.io/docs/zrok/1.1/guides/self-hosting/interstitial-page/

The temporary anonymous probe identity, its app row and probe sessions were removed after testing.
