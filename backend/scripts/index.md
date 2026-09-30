# backend/scripts — index

| File | Holds |
| --- | --- |
| `provision-roles.ts` | gives the two runtime roles a login and a password, from the environment |

## Why this is not a migration

A password in a `.sql` file is a password in version control. The migrations create the roles with
the right attributes and **no login**; this script is the only thing that hands out a credential, and
it reads it from the environment.

It also asserts the two roles that must not be able to log in still cannot, so a later change to the
migrations cannot quietly turn the resolver or the owner into a usable account.

Requires `DATABASE_ADMIN_URL` — the project admin role, not the API role — plus
`SWIFTTERM_API_PASSWORD` and `SWIFTTERM_MIGRATOR_PASSWORD`, each at least 24 characters. Quoting is
done by `format(%I, %L)` in the database, so a password is never interpolated by hand.
