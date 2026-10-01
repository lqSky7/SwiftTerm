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

The key is the client key — **`anon` `public`**, or its replacement **`publishable`** — from
[Settings → API Keys](https://supabase.com/dashboard/project/upmarjiewuwvaljnnboq/settings/api-keys/).
It is publishable and safe to embed: it authorises the *client*, and every row is still scoped by
row-level security and by the backend's own signature check. The **`secret`** key (formerly
`service_role`) must never go in either file.

The quickest way to get both values at once is the project's **Connect** dialog:
[project home → Connect](https://supabase.com/dashboard/project/upmarjiewuwvaljnnboq?showConnect=true)
shows the URL and the client key ready to copy.

**An account has to exist before anyone can sign in**, and neither the app nor the website creates
one. The dashboard's
[Authentication → Users](https://supabase.com/dashboard/project/upmarjiewuwvaljnnboq/auth/users) page
adds one; confirm the email if the project asks for it.

### Which key, and why it is safe in a client

**The publishable key.** It is labelled `Publishable key` on
[Settings → API Keys](https://supabase.com/dashboard/project/upmarjiewuwvaljnnboq/settings/api-keys/)
and starts with `sb_publishable_`. The **`sb_secret_`** key below it is a different thing and must
never appear in either file.

`Info.plist` is inside the app bundle, so anyone who has the app can read it — and that is true of
every key in every client, which is exactly why this one is *designed* to be there. Supabase
documents the publishable key as safe in "web page, mobile or desktop app, GitHub actions, CLIs,
source code".

**The protection is not the key's secrecy; it is that the key cannot reach your data.** Verified
against this project:

| Check | Result |
| --- | --- |
| `anon` / `authenticated` `USAGE` on the `swiftterm` schema | **false** — they cannot see it exists |
| `anon` / `authenticated` `SELECT` on any of the nine `swiftterm` tables | **false** for all nine |
| Tables and views in `public` — the schema PostgREST *does* expose | **none** |
| Can `anon` create anything in `public`? | **no** |

So a decompiled app yields a key that can reach nothing. The only credential that touches
`swiftterm.*` is `swiftterm_api`, which lives in `backend/.env` on the server and is never given to a
client.

The **`sb_secret_`** key is the opposite: it resolves to `service_role`, which has `BYPASSRLS` and
therefore bypasses every policy above. It belongs in `backend/.env` if anywhere, and you most likely
do not need it at all.

**One caveat, stated because it is untested:** a publishable key is *not* a JWT. The app sends it as
the `apikey` header for the password grant, which is where Supabase says publishable keys go — but
that exact combination has not been exercised here. If sign-in answers `Invalid API key`, use the
**Legacy anon, service_role API keys** tab and the `anon` JWT instead; that one is certainly
accepted, because GoTrue's own error message names it.

### Until the key is set

Both sign-in screens say sign-in is not set up and link to the page above, rather than showing a bare
token field. There is a second path, which is a **pasted access token** — the backend verifies it
exactly as it verifies one from the password grant, so it is not a bypass. It is **off unless a build
turns it on**, because its only audience is whoever is building the thing and a shipped build should
not show a credential-paste field to whoever opens it:

| | |
| --- | --- |
| Mac app | `SwiftTermAllowTokenSignIn` → `<true/>` in `app/Info.plist` (absent means off) |
| Website | `NEXT_PUBLIC_ALLOW_TOKEN_SIGN_IN=1` in `.env.local` |

This produces a token, given the anon key and an account that already exists:

```bash
curl -s -X POST \
  'https://upmarjiewuwvaljnnboq.supabase.co/auth/v1/token?grant_type=password' \
  -H 'apikey: <ANON_KEY>' -H 'content-type: application/json' \
  -d '{"email":"you@example.com","password":"..."}' | jq -r .access_token
```

It lasts about an hour, and there is nothing to refresh it with — which is why the password path is
the real one and this is the escape hatch.

### What the token is, and what it is not

It is **not** a database credential, and it cannot read the database. `…supabase.co/auth/v1` is
Supabase **Auth** — a separate service that happens to share a project with the Postgres instance.
Postgres never issues it. It is a signed pass that Auth issues when somebody logs in, and the backend
verifies its signature against the project's published keys before trusting a single claim in it. The
only thing holding a database credential is the backend service itself; the app and the browser never
get one.


