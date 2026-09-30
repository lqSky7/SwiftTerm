# website — index

The browser-facing surface: sign-in, the account and device list, and later the live viewer. Next.js
16 App Router, React 19, Tailwind v4, shadcn-style components, Geist.

**This is a recorded divergence from the handoff.** `implementation-handoff.md` fixes the website as
"TypeScript + Vite, DOM components and Canvas 2D; no React/UI framework". The human chose Next.js and
`lqSky7/aside-clone` as the base instead, so the rule is overridden rather than broken by accident.
Everything the handoff says about *rendering* still holds and matters more now, not less: escaped
`textContent` for block and header text, a canvas for the grid, no `innerHTML`, no second VT parser.
See `src/app/index.md`.

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

## Running it

```sh
cp .env.example .env.local     # gitignored
npm install
npm run dev                    # http://localhost:3000
npm run check                  # typecheck + production build
```

The backend must be running and must list this origin in `ALLOWED_ORIGINS`, because every write is
checked against it. In production the website and the API share an origin.

## Status

B1A's website scope only: sign-in, account, device list. There is no live viewer — that is B2C, and
it needs the relay from B2A first. This page deliberately does not show a session list it cannot yet
populate.
