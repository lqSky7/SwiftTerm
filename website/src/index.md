# website/src — index

| Path | Holds |
| --- | --- |
| `app/` | routes and the design tokens |
| `components/` | the chrome and the mark |
| `auth/` | session and device calls against the backend |
| `lib/` | the API client and small utilities |

## The one rule that spans all of it

**The website never holds a credential it could leak.** It has no database URL, no device token and
no session secret — only a session cookie the backend minted, plus the CSRF token it must echo back
in a header on every write. Device tokens belong to the native app and stay in its Keychain.

That is why `lib/api.ts` always sends `credentials: "include"` and always echoes the CSRF header,
and why `auth/client.ts` contains no secret of its own.

Production API calls and live sockets use `/api` on the website origin through worker.ts.
