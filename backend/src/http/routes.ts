/**
 * The endpoints.
 *
 * Every cookie-authenticated write goes through `requireSession` **and** `requireCsrf`. The CSRF
 * check has two independent halves and needs both: the header must hash to the digest stored
 * against this session, and the request must carry an `Origin` we allow. A cookie on its own is
 * never sufficient, which is the rule the handoff states — and the reason the CSRF token is a
 * second, independently generated secret rather than a copy of the session token.
 */

import type { Config } from "../config.ts";
import type { Database } from "../db/pool.ts";
import {
  createWebSession,
  listDevices,
  provisionAppUser,
  readOwnAccount,
  resolveWebSession,
  revokeDevice,
  revokeWebSession,
} from "../db/resolvers.ts";
import { DeviceConflictError, DeviceRequestError, registerDeviceForOwner } from "../auth/devices.ts";
import { IdentityError, type IdentityVerifier } from "../auth/oidc.ts";
import {
  FailureRateLimiter,
  clearedSessionCookies,
  digestsEqual,
  randomToken,
  sessionCookies,
  sha256,
  type AuthenticatedSession,
} from "../auth/session.ts";
import { HttpError, type RequestContext, type HttpResponse, type Route } from "./server.ts";

export interface RouteDependencies {
  readonly config: Config;
  readonly db: Database;
  readonly verifier: IdentityVerifier;
  readonly limiter: FailureRateLimiter;
}

/** Coarse key for the rate limit. Deliberately not the credential itself. */
function rateLimitKey(context: RequestContext): string {
  const forwarded = context.headers["x-forwarded-for"];
  const address =
    typeof forwarded === "string"
      ? (forwarded.split(",")[0] as string).trim()
      : (context.headers["x-real-ip"] as string | undefined) ?? "unknown";
  return address;
}

/** A present but disallowed `Origin` is refused. An absent one is a non-browser caller. */
function assertOriginAllowed(context: RequestContext, config: Config): void {
  const origin = context.headers.origin;
  if (origin === undefined) return;
  if (!config.allowedOrigins.includes(origin)) {
    throw HttpError.forbidden("origin not allowed");
  }
}

async function requireSession(
  context: RequestContext,
  dependencies: RouteDependencies,
): Promise<AuthenticatedSession> {
  const token = context.cookies.get(dependencies.config.cookieName);
  if (token === undefined || token === "") throw HttpError.unauthorized();

  const key = rateLimitKey(context);
  // Before the hash and the query: a flood of garbage cookies must not reach the database.
  if (!dependencies.limiter.tryConsume(key)) throw HttpError.rateLimited();

  const resolved = await resolveWebSession(dependencies.db, sha256(token));
  if (resolved === null) throw HttpError.unauthorized();
  dependencies.limiter.reset(key);

  if (resolved.revokedAt !== null) throw HttpError.sessionEnded();
  if (resolved.accountDeactivatedAt !== null) throw HttpError.sessionEnded();
  if (resolved.expiresAt.getTime() <= Date.now()) throw HttpError.sessionEnded();

  return {
    sessionId: resolved.sessionId,
    ownerId: resolved.ownerId,
    csrfSha256: resolved.csrfSha256,
    expiresAt: resolved.expiresAt,
  };
}

/** Both halves of the CSRF rule, for any cookie-authenticated write. */
function requireCsrf(
  context: RequestContext,
  session: AuthenticatedSession,
  config: Config,
): void {
  const origin = context.headers.origin;
  if (origin === undefined || !config.allowedOrigins.includes(origin)) {
    throw HttpError.forbidden("a write requires an allowed Origin");
  }
  const header = context.headers[config.csrfHeaderName];
  if (typeof header !== "string" || header === "") {
    throw HttpError.forbidden(`missing ${config.csrfHeaderName}`);
  }
  if (!digestsEqual(sha256(header), session.csrfSha256)) {
    throw HttpError.forbidden("CSRF token does not match this session");
  }
}

function asObject(body: unknown): Record<string, unknown> {
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    throw HttpError.invalid("expected a JSON object");
  }
  return body as Record<string, unknown>;
}

export function buildRoutes(dependencies: RouteDependencies): Route[] {
  const { config, db, verifier } = dependencies;

  return [
    {
      method: "GET",
      path: "/healthz",
      handler: async (): Promise<HttpResponse> => {
        const healthy = await db.ping();
        return { status: healthy ? 200 : 503, body: { status: healthy ? "ok" : "degraded" } };
      },
    },

    {
      method: "POST",
      path: "/auth/session",
      handler: async (context): Promise<HttpResponse> => {
        assertOriginAllowed(context, config);
        const body = asObject(context.body);
        const accessToken = body.access_token;
        if (typeof accessToken !== "string" || accessToken === "") {
          throw HttpError.invalid("access_token is required");
        }

        let identity;
        try {
          identity = await verifier.verify(accessToken);
        } catch (error) {
          if (error instanceof IdentityError) throw HttpError.unauthorized("token not accepted");
          throw error;
        }

        // The account is created from the *verified* issuer and subject, never from request JSON.
        const ownerId = await provisionAppUser(
          db,
          identity.issuer,
          identity.subject,
          identity.displayName,
        );

        const sessionToken = randomToken().toString("base64url");
        const csrfToken = randomToken().toString("base64url");
        const sessionId = await createWebSession(
          db,
          ownerId,
          sha256(sessionToken),
          sha256(csrfToken),
          config.sessionTtlHours,
        );

        return {
          status: 201,
          body: { session_id: sessionId, csrf_token: csrfToken, expires_in_hours: config.sessionTtlHours },
          cookies: sessionCookies(
            { sessionId, sessionToken, csrfToken, expiresAt: new Date(Date.now() + config.sessionTtlHours * 3_600_000) },
            { session: config.cookieName, csrf: config.csrfCookieName },
            config,
          ),
        };
      },
    },

    {
      method: "GET",
      path: "/auth/csrf",
      handler: async (context): Promise<HttpResponse> => {
        const session = await requireSession(context, dependencies);
        // The token itself, not the digest. It is not the session secret and the page has to echo
        // it back in a header; the cookie is only a convenience copy.
        const csrfToken = context.cookies.get(config.csrfCookieName);
        if (csrfToken === undefined || !digestsEqual(sha256(csrfToken), session.csrfSha256)) {
          throw HttpError.sessionEnded();
        }
        return { body: { csrf_token: csrfToken, expires_at: session.expiresAt.toISOString() } };
      },
    },

    {
      method: "POST",
      path: "/auth/logout",
      handler: async (context): Promise<HttpResponse> => {
        const session = await requireSession(context, dependencies);
        requireCsrf(context, session, config);
        await revokeWebSession(db, session.ownerId, session.sessionId);
        // Logout revokes the session row; live sockets are closed by the relay in B2A.
        return {
          status: 204,
          cookies: clearedSessionCookies(
            { session: config.cookieName, csrf: config.csrfCookieName },
            config,
          ),
        };
      },
    },

    {
      method: "GET",
      path: "/me",
      handler: async (context): Promise<HttpResponse> => {
        const session = await requireSession(context, dependencies);
        const account = await readOwnAccount(db, session.ownerId);
        if (account === null) throw HttpError.sessionEnded();
        return {
          body: {
            id: account.id,
            display_name: account.displayName,
            created_at: account.createdAt.toISOString(),
            deactivated_at: account.deactivatedAt?.toISOString() ?? null,
          },
        };
      },
    },

    {
      method: "GET",
      path: "/devices",
      handler: async (context): Promise<HttpResponse> => {
        const session = await requireSession(context, dependencies);
        const devices = await listDevices(db, session.ownerId);
        return {
          body: {
            devices: devices.map((device) => ({
              id: device.id,
              label: device.label,
              client_request_id: device.clientRequestId,
              created_at: device.createdAt.toISOString(),
              revoked_at: device.revokedAt?.toISOString() ?? null,
            })),
          },
        };
      },
    },

    {
      method: "POST",
      path: "/devices",
      handler: async (context): Promise<HttpResponse> => {
        const session = await requireSession(context, dependencies);
        requireCsrf(context, session, config);
        const body = asObject(context.body);
        try {
          const result = await registerDeviceForOwner(db, session.ownerId, {
            label: body.label,
            clientRequestId: body.client_request_id,
            deviceToken: body.device_token,
          });
          return {
            status: result.created ? 201 : 200,
            body: { device_id: result.deviceId, created: result.created },
          };
        } catch (error) {
          if (error instanceof DeviceConflictError) {
            throw HttpError.conflict("client_request_id reused with a different payload");
          }
          if (error instanceof DeviceRequestError) throw HttpError.invalid(error.message);
          throw error;
        }
      },
    },

    {
      method: "DELETE",
      path: "/devices/:id",
      handler: async (context, params): Promise<HttpResponse> => {
        const session = await requireSession(context, dependencies);
        requireCsrf(context, session, config);
        const deviceId = params.id ?? "";
        if (!/^[0-9a-f-]{36}$/.test(deviceId)) throw HttpError.invalid("device id must be a UUID");
        const revoked = await revokeDevice(db, session.ownerId, deviceId);
        // A device the caller does not own is reported as absent, so the endpoint cannot be used to
        // probe which ids exist.
        if (!revoked) throw HttpError.notFound();
        return { status: 204 };
      },
    },
  ];
}
