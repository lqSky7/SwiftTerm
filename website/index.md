# website — index

The browser-facing surface: sign-in, the account and device list, and the live viewer. Next.js 16 App
Router, React 19, Tailwind v4, shadcn-style components, Geist.

**This is a recorded divergence from the handoff.** `implementation-handoff.md` fixes the website as
"TypeScript + Vite, DOM components and Canvas 2D; no React/UI framework". The human chose Next.js and
`lqSky7/aside-clone` as the base instead, so the rule is overridden rather than broken by accident.
Everything the handoff says about *rendering* still holds and matters more now, not less: escaped
`textContent` for block and header text, a canvas for the grid, no `innerHTML`, no second VT parser.
See `src/app/index.md` and `src/shared_session/index.md`.

| Path | Holds |
| --- | --- |
| `src/app/` | the routes: `/`, `/sign-in`, `/account`, `/live` |
| `src/auth/` | the Supabase client, and the exchange that turns a token into a session |
| `src/lib/` | the API client, and the CSRF rule it always follows |
| `src/shared_session/` | the live viewer: reducer, socket, canvas, palette |
| `test/` | the viewer's reducer and socket tests, run with `node --test` |

## Design language

Taken verbatim from aside-clone so the two surfaces read as one product:

| | |
| --- | --- |
| Tokens | achromatic `oklch`; every token is `oklch(L 0 0)` |
| Radius | `--radius: 0.625rem`, with `sm`/`md`/`lg`/`xl` derived from it |
| Type | Geist for UI, Geist Mono for anything in a cell |
| Chrome | a 56px sticky bar, mark left, centred links, account control right |

`--destructive` is the only saturated token and is reserved for genuine destructive actions. The
SwiftTerm mark in `src/components/logo.tsx` inherits `currentColor` and has no accent fill of its
own — the interface must not contain a colour the token set does not define.

**The one exception is inside a terminal grid**, and it is not an exception to the rule so much as a
different surface: a cell's colours come from the host's own palette, because a terminal that
repainted `ls` output in greyscale would be lying about what the program printed.

## Running it

```sh
cp .env.example .env.local     # gitignored
npm install
npm run dev                    # http://localhost:3000
npm run check                  # typecheck + tests + production build
```

The backend must be running and must list this origin in `ALLOWED_ORIGINS`, because every write is
checked against it. In production the website and the API share an origin.

The site is a **static export** (`output: "export"`), served by Cloudflare with a small API proxy. That is why
the live viewer's session id is a query parameter rather than a path segment: a dynamic route would
need every id enumerated at build time.

## Deployment

`worker.ts` proxies `/api/*` to the fixed `API_UPSTREAM` zrok origin, with the prefix removed.
Cookies, Origin, CSRF headers and WebSocket upgrades pass through; redirects are not followed.
The browser contacts the website origin for HTTP and WebSockets. The backend remains behind zrok.
Cloudflare serves the static Next.js export through the ASSETS binding for all other routes.
This repairs the cross-origin browser path without adding a Next.js server or another deployment.

`npm run check` passes 65 tests, typechecking and static export. `npx wrangler deploy` publishes
both the proxy and assets. For local Next.js development set NEXT_PUBLIC_API_BASE_URL to the local
backend; in production omit it or set `/api`. Supabase Auth remains its own issuer origin.

The Worker sets skip_zrok_interstitial for upstream API/socket requests: browser user-agents otherwise receive zrok HTML instead of API JSON.
