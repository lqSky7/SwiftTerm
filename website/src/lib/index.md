# website/src/lib — index

| File | Holds |
| --- | --- |
| `api.ts` | the backend client: base URL, credentials, CSRF header, allowlisted error codes |
| `utils.ts` | `cn`, the class merge helper |

## Two things `api.ts` always does

**`credentials: "include"`.** The session is a cookie. A fetch that forgets this is
unauthenticated and looks exactly like a broken session.

**Echoes the CSRF header on every non-GET.** The backend checks that header against the digest
stored against the session *and* checks the Origin. The readable cookie is only a convenient place
to keep the token; presenting it without the header is not sufficient and is meant not to be.

## Errors are codes, not prose

`ApiError` carries the allowlisted protocol code and derives a person-readable message from it. The
backend never sends a diagnostic, so there is nothing else to show — and inventing one here would
mean inventing a reason the server deliberately withheld.
