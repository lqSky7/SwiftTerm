# backend/src/http — index

| File | Holds |
| --- | --- |
| `server.ts` | routing, bounded bodies, cookies, security headers, and the one place an error becomes a status |
| `routes.ts` | the endpoints, `requireSession` and `requireCsrf` |
| `main.ts` | the entrypoint: configuration, pool, verifier, routes, listen, graceful shutdown |

## Endpoints

| Method | Path | Auth |
| --- | --- | --- |
| `GET` | `/healthz` | none — a readiness probe that touches the database |
| `POST` | `/auth/session` | a verified OIDC access token in the body |
| `GET` | `/auth/csrf` | session |
| `POST` | `/auth/logout` | session + CSRF |
| `GET` | `/me` | session |
| `GET` | `/devices` | session |
| `POST` | `/devices` | session + CSRF |
| `DELETE` | `/devices/:id` | session + CSRF |

## Deliberate properties

**Bodies are bounded before they are parsed.** `Content-Length` is checked first, so an oversized
body is refused without being read at all; the running total is checked too, because a chunked
request has no declared length and would otherwise stream past the cap.

**Errors never leak a diagnostic.** A rejection carries an allowlisted code and the reason stays in
the log — the same rule as a malformed wire frame not echoing a payload back.

**`no-store` on every response.** Sessions and share content must not sit in a shared cache.

**CORS is an exact-origin echo with credentials, never a wildcard.** Production serves the website
from the same origin, so this exists for local development and nothing else.

**A device the caller does not own is reported as absent, not forbidden.** `DELETE /devices/:id`
answers 404 rather than 403 so the endpoint cannot be used to probe which ids exist.

## Not here yet

The WebSocket relay, one-use tickets and the share endpoints belong to B2A and B5B. There is no
socket code in this directory, and `POST /auth/logout` does not yet close live sockets — the session
row is revoked, which is what B2A's relay will consult.
