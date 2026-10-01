# Account — index

| File | Responsibility |
| --- | --- |
| `AccountController.swift` | Observable identity, owned authentication tasks, restore, device registration and revocation |
| `SignInFlow.swift` | Supabase password/anonymous/settings/refresh requests and Keychain refresh credential |
| `AccountWindowController.swift` | Native grouped account window, device list and revoke confirmation |
| `ShareSheet.swift` | Pane sharing and reusable sign-in section; Account button opens device management |

Account is reachable from Settings and the sharing sheet. The OS profile stays separate.
Anonymous availability comes from public project settings when sign-in is opened. Closing a pending
sign-in cancels both the issuer request and API exchange. The app does no cloud work on startup;
opening Account or Share explicitly restores a saved refresh credential. Sign-out clears that token,
ends sharing through AppCore, and leaves local shells running.

Device secrets and stable registration request IDs are scoped to cloud account IDs. A revoked
registration rotates its secret and request ID; failed device lookup preserves the existing secret.
`Tests/sign-in-test.swift` covers issuer responses without network or real Keychain mutations.
