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
import {
  admitPublisher,
  canonicalRequestDigest,
  createLiveSession,
  endDeviceSessions,
  endLiveSession,
  listLiveSessions,
  newLeaseToken,
  readLiveSession,
  type LiveSessionRow,
} from "../shared_session/live.ts";
import { mintTicket } from "../shared_session/socket.ts";
import type { SessionRegistry } from "../shared_session/sessions.ts";
import type { TicketStore } from "../shared_session/tickets.ts";
import { HttpError, type RequestContext, type HttpResponse, type Route } from "./server.ts";

/**
 * What the live routes need from the relay.
 *
 * Passed in rather than imported so the routes stay testable without a listening socket, and so
 * there is exactly one registry and one ticket store per process.
 */
export interface RelayControl {
  readonly registry: SessionRegistry;
  readonly tickets: TicketStore;
  /** Close the sockets attached to a session. Used when it ends or its device is revoked. */
  closeSession(sessionId: string, code: number, reason: string): void;
}

export interface RouteDependencies {
  readonly config: Config;
  readonly db: Database;
  readonly verifier: IdentityVerifier;
  readonly limiter: FailureRateLimiter;
  readonly relay: RelayControl;
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

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** Canonical lowercase UUID or nothing. A braced or uppercase id is refused, not normalised. */
function requireUuid(value: unknown, field: string): string {
  if (typeof value !== "string" || !UUID_PATTERN.test(value)) {
    throw HttpError.invalid(`${field} must be a lowercase UUID`);
  }
  return value;
}

/** How a stream is described on the wire. Timestamps are ISO-8601 in UTC. */
function serialiseSession(row: LiveSessionRow): Record<string, unknown> {
  return {
    id: row.id,
    device_id: row.deviceId,
    local_pane_id: row.localPaneId,
    title: row.title,
    status: row.status,
    publisher_epoch: String(row.publisherEpoch),
    created_at: row.createdAt.toISOString(),
    expires_at: row.expiresAt.toISOString(),
    ended_at: row.endedAt?.toISOString() ?? null,
  };
}

/**
 * The keyset cursor, as `<created_at>|<id>`.
 *
 * A single opaque string rather than two query parameters, because the pair is one cursor and
 * splitting it invites a caller to send half of it. `created_at` alone is not unique, so the id is
 * what makes the position exact.
 */
function parseCursor(raw: string | null): { beforeCreatedAt: Date; beforeId: string } | null {
  if (raw === null || raw === "") return null;
  const separator = raw.lastIndexOf("|");
  if (separator <= 0) throw HttpError.invalid("cursor must be <created_at>|<id>");
  const createdAt = new Date(raw.slice(0, separator));
  if (Number.isNaN(createdAt.getTime())) throw HttpError.invalid("cursor timestamp is not a date");
  return { beforeCreatedAt: createdAt, beforeId: requireUuid(raw.slice(separator + 1), "cursor id") };
}

const DEFAULT_PAGE = 50;
const MAX_PAGE = 100;

function parseLimit(raw: string | null): number {
  if (raw === null || raw === "") return DEFAULT_PAGE;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 1) throw HttpError.invalid("limit must be a positive integer");
  return Math.min(value, MAX_PAGE);
}

/** A refusal from the database, as an HTTP status. */
function liveRefusal(outcome: string): HttpError {
  switch (outcome) {
    case "conflict":
      return HttpError.conflict("client_request_id reused with a different payload");
    case "pane_shared":
      return HttpError.conflict("that pane is already being shared");
    case "account_limit":
      return new HttpError(429, "capacity", "too many open streams for this account");
    case "device_unknown":
      // Not 403: a device id the caller does not own and one that never existed are the same answer,
      // so the endpoint cannot be used to probe which ids exist.
      return HttpError.notFound();
    default:
      return new HttpError(500, "invalid_frame", "unhandled outcome");
  }
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

        // Revoking a credential has to stop what it was doing. The streams are ended in the database
        // first — that is what fences a ticket already in flight — and only then are the sockets
        // closed, so a socket that reconnects mid-teardown finds an ended session rather than a
        // live one.
        for (const sessionId of await endDeviceSessions(db, session.ownerId, deviceId)) {
          dependencies.relay.registry.end(sessionId);
          dependencies.relay.closeSession(sessionId, 4404, "device_revoked");
        }
        return { status: 204 };
      },
    },

    // MARK: - Live sessions

    {
      method: "POST",
      path: "/live",
      handler: async (context): Promise<HttpResponse> => {
        const session = await requireSession(context, dependencies);
        requireCsrf(context, session, config);
        const body = asObject(context.body);

        const deviceId = requireUuid(body.device_id, "device_id");
        const localPaneId = requireUuid(body.local_pane_id, "local_pane_id");
        const clientRequestId = requireUuid(body.client_request_id, "client_request_id");
        const title = body.title === undefined ? "" : body.title;
        if (typeof title !== "string") throw HttpError.invalid("title must be a string");

        const result = await createLiveSession(db, session.ownerId, {
          deviceId,
          localPaneId,
          clientRequestId,
          // The digest covers exactly the fields that define the request, so a retry with a
          // different title is a conflict rather than the same stream under a new name.
          requestSha256: canonicalRequestDigest({
            device_id: deviceId,
            local_pane_id: localPaneId,
            title,
          }),
          title,
          maxStreams: config.maxLiveStreamsPerAccount,
        });

        if (result.outcome !== "created" && result.outcome !== "existing") {
          throw liveRefusal(result.outcome);
        }
        if (result.sessionId === null) throw new HttpError(500, "invalid_frame", "no session id");

        // Register it in this process so the socket path resolves. Idempotent, so a retry is cheap.
        const opened = dependencies.relay.registry.open({
          sessionId: result.sessionId,
          ownerId: session.ownerId,
          deviceId,
          localPaneId,
          publisherEpoch: result.publisherEpoch ?? 0,
          title,
        });
        if (!opened.ok) {
          throw new HttpError(429, "capacity", "this relay is at its publisher limit");
        }

        return {
          status: result.outcome === "created" ? 201 : 200,
          body: {
            session_id: result.sessionId,
            status: result.status,
            publisher_epoch: String(result.publisherEpoch ?? 0),
            created: result.outcome === "created",
          },
        };
      },
    },

    {
      method: "GET",
      path: "/live",
      handler: async (context): Promise<HttpResponse> => {
        const session = await requireSession(context, dependencies);
        const cursor = parseCursor(context.url.searchParams.get("before"));
        const limit = parseLimit(context.url.searchParams.get("limit"));

        const rows = await listLiveSessions(db, session.ownerId, {
          ...(cursor === null ? {} : cursor),
          limit,
        });
        const last = rows[rows.length - 1];
        return {
          body: {
            sessions: rows.map(serialiseSession),
            // Only offered when the page was full, because a short page is the end of the list and
            // a cursor there would invite one more empty request.
            next_before:
              rows.length === limit && last !== undefined
                ? `${last.createdAt.toISOString()}|${last.id}`
                : null,
          },
        };
      },
    },

    {
      method: "POST",
      path: "/live/:id/tickets",
      handler: async (context, params): Promise<HttpResponse> => {
        const session = await requireSession(context, dependencies);
        requireCsrf(context, session, config);
        const sessionId = requireUuid(params.id ?? "", "session id");
        const body = asObject(context.body);
        const role = body.role;
        if (role !== "publisher" && role !== "viewer") {
          throw HttpError.invalid("role must be publisher or viewer");
        }

        const live = await readLiveSession(db, session.ownerId, sessionId);
        if (live === null) throw HttpError.notFound();
        // Ended and expired are the same answer to a caller: the session is not available. They are
        // separated in the database because the relay's behaviour differs, not because the client
        // should treat them differently.
        if (live.status === "ended") {
          throw new HttpError(409, "session_ended", "that session has ended");
        }
        if (live.expiresAt.getTime() <= Date.now()) {
          throw new HttpError(409, "session_ended", "that session has expired");
        }

        if (role === "viewer") {
          // A viewer ticket is minted against the epoch the session is in, which the relay then
          // reports to the viewer in the retained hello. A viewer never advances it.
          const opened = dependencies.relay.registry.open({
            sessionId,
            ownerId: session.ownerId,
            deviceId: live.deviceId,
            localPaneId: live.localPaneId,
            publisherEpoch: live.publisherEpoch,
            title: live.title,
          });
          if (!opened.ok) {
            throw new HttpError(429, "capacity", "this relay is at its publisher limit");
          }
          const minted = mintTicket(dependencies.relay.tickets, {
            sessionId,
            accountId: session.ownerId,
            role: "viewer",
            epoch: String(opened.session.epoch),
          });
          return {
            status: 201,
            body: {
              ticket: minted.ticket,
              expires_at: new Date(minted.expiresAt).toISOString(),
              role: "viewer",
              epoch: String(opened.session.epoch),
            },
          };
        }

        // The publisher. The relay is registered before the database is touched, so a process at its
        // own limit refuses without taking a lease it cannot serve.
        const opened = dependencies.relay.registry.open({
          sessionId,
          ownerId: session.ownerId,
          deviceId: live.deviceId,
          localPaneId: live.localPaneId,
          publisherEpoch: live.publisherEpoch,
          title: live.title,
        });
        if (!opened.ok) {
          throw new HttpError(429, "capacity", "this relay is at its publisher limit");
        }

        const leaseToken = newLeaseToken();
        const admitted = await admitPublisher(db, session.ownerId, {
          sessionId,
          deviceId: live.deviceId,
          leaseToken,
        });
        switch (admitted.outcome) {
          case "admitted":
            break;
          case "not_found":
            throw HttpError.notFound();
          case "ended":
          case "expired":
            throw new HttpError(409, "session_ended", "that session is no longer available");
          case "device_mismatch":
            // The session belongs to another device of the same account, so this device is not its
            // publisher even though the account is right.
            throw HttpError.forbidden("that session belongs to another device");
          case "busy":
            throw new HttpError(409, "stale_lease", "a publisher already holds this session");
        }

        opened.session.adoptEpoch(admitted.publisherEpoch);
        const minted = mintTicket(dependencies.relay.tickets, {
          sessionId,
          accountId: session.ownerId,
          role: "publisher",
          deviceId: live.deviceId,
          leaseToken,
          epoch: String(admitted.publisherEpoch),
        });
        return {
          status: 201,
          body: {
            ticket: minted.ticket,
            expires_at: new Date(minted.expiresAt).toISOString(),
            role: "publisher",
            epoch: String(admitted.publisherEpoch),
          },
        };
      },
    },

    {
      method: "POST",
      path: "/live/:id/end",
      handler: async (context, params): Promise<HttpResponse> => {
        const session = await requireSession(context, dependencies);
        requireCsrf(context, session, config);
        const sessionId = requireUuid(params.id ?? "", "session id");

        const result = await endLiveSession(db, session.ownerId, sessionId);
        if (!result.found) throw HttpError.notFound();

        // Database first, sockets second. A socket that reconnects during the teardown finds an
        // ended session rather than a live one.
        dependencies.relay.registry.end(sessionId);
        dependencies.relay.closeSession(sessionId, 4404, "session_ended");
        // Idempotent: a second call reports no change and still succeeds, so a client retry after a
        // dropped response does not look like a failure.
        return { status: 204 };
      },
    },
  ];
}
