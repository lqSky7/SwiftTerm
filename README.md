# swiftTerm

A native macOS terminal that takes the *product* ideas from Warp and implements them on Apple's own
stack — AppKit, SwiftUI, CoreText — with no third-party dependencies.

Targets macOS 26+ only, Swift 6 language mode. See [`docs/phases.md`](docs/phases.md) for the plan
and [`docs/phase-1.md`](docs/phase-1.md) for what Phase 1 is.

```bash
./Scripts/run-tests.sh     # the standalone harnesses
./Scripts/lint.sh          # swiftlint + the pure-model gate
./Scripts/run.sh           # build, install to /Applications, launch
```

## Accounts and signing in

The terminal works with no account at all. An account is only needed to **share** a pane, because a
stream belongs to an account and a browser watching it has to be revocable.

Sign-in is a password grant against Supabase Auth, then an exchange at the backend for a session
cookie. The backend verifies the token's signature against the project's published keys — it never
sees a password, and the app never holds a database credential.

**Two values make that work, and one of them is not in this repository:**

| Where | Key | Value |
| --- | --- | --- |
| `app/Info.plist` | `SwiftTermSupabaseURL` | already set |
| `app/Info.plist` | `SwiftTermSupabaseAnonKey` | **you have to supply this** |
| `website/.env.local` | `NEXT_PUBLIC_SUPABASE_URL` | the same URL |
| `website/.env.local` | `NEXT_PUBLIC_SUPABASE_ANON_KEY` | the same key |

The key is the **`anon` `public`** key, from
[Project Settings → API](https://supabase.com/dashboard/project/upmarjiewuwvaljnnboq/settings/api).
It is publishable and safe to embed: it authorises the *client*, and every row is still scoped by
row-level security and by the backend's own signature check. The `service_role` key must never go in
either file.

**An account has to exist before anyone can sign in**, and neither the app nor the website creates
one. The dashboard's
[Authentication → Users](https://supabase.com/dashboard/project/upmarjiewuwvaljnnboq/auth/users) page
adds one; confirm the email if the project asks for it.

### Until the key is set

Both sign-in screens say so and link to the page above, rather than showing a bare token field. There
is a second path for testing, which is a **pasted access token**: the backend verifies it exactly as
it verifies one from the password grant, so it is not a bypass. This produces one, given the anon key
and an account that already exists:

```bash
curl -s -X POST \
  'https://upmarjiewuwvaljnnboq.supabase.co/auth/v1/token?grant_type=password' \
  -H 'apikey: <ANON_KEY>' -H 'content-type: application/json' \
  -d '{"email":"you@example.com","password":"..."}' | jq -r .access_token
```

It lasts about an hour, and there is nothing to refresh it with — which is why the password path is
the real one and this is the escape hatch.

