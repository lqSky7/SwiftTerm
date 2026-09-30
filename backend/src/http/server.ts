/**
 * The HTTP server: routing, bounded bodies, cookies, and the one place an error becomes a status.
 *
 * Deliberate properties:
 *
 *   * **Bodies are bounded before they are parsed.** A `Content-Length` over the cap is refused
 *     without reading, and a chunked body that grows past the cap is destroyed mid-stream rather
 *     than buffered. Nothing here accumulates an attacker-sized buffer.
 *   * **Errors never leak a diagnostic.** A rejection carries an allowlisted code; the message
 *     stays in the log. The handoff's rule that a malformed frame must not echo a payload back is
 *     the same rule at the HTTP layer.
 *   * **`no-store` on every response.** Sessions and share content must not sit in a shared cache.
 *   * **CORS is an exact-origin echo with credentials, never a wildcard.** Production serves the
 *     website from the same origin, so this exists for local development and for nothing else.
 */

import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";

import type { Config } from "../config.ts";
import { parseCookies } from "../auth/session.ts";

export const MAX_JSON_BODY_BYTES = 64 * 1024;

export class HttpError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string, message: string) {
    super(message);
    this.name = "HttpError";
    this.status = status;
    this.code = code;
  }

  static unauthorized(message = "authentication required"): HttpError {
    return new HttpError(401, "unauthorized", message);
  }

  static invalid(message: string): HttpError {
    return new HttpError(400, "invalid_frame", message);
  }

  static forbidden(message = "not allowed"): HttpError {
    return new HttpError(403, "unauthorized", message);
  }

  static notFound(): HttpError {
    return new HttpError(404, "invalid_frame", "not found");
  }

  static conflict(message: string): HttpError {
    return new HttpError(409, "invalid_frame", message);
  }

  static rateLimited(): HttpError {
    return new HttpError(429, "rate_limited", "too many attempts");
  }

  static sessionEnded(): HttpError {
    return new HttpError(401, "session_ended", "session ended");
  }
}

export interface RequestContext {
  readonly method: string;
  readonly url: URL;
  readonly headers: IncomingHttpHeaders;
  readonly cookies: Map<string, string>;
  readonly body: unknown;
}

export interface HttpResponse {
  readonly status?: number;
  readonly body?: unknown;
  /** `Set-Cookie` values. Each entry is one cookie. */
  readonly cookies?: readonly string[];
  readonly headers?: Readonly<Record<string, string>>;
}

export interface Route {
  readonly method: string;
  /** Path segments; a segment starting with `:` captures into `params`. */
  readonly path: string;
  readonly handler: (context: RequestContext, params: Record<string, string>) => Promise<HttpResponse>;
}

type IncomingHttpHeaders = IncomingMessage["headers"];

function matchRoute(
  route: Route,
  method: string,
  pathname: string,
): Record<string, string> | null {
  if (route.method !== method) return null;
  const expected = route.path.split("/").filter((segment) => segment !== "");
  const actual = pathname.split("/").filter((segment) => segment !== "");
  if (expected.length !== actual.length) return null;
  const params: Record<string, string> = {};
  for (let index = 0; index < expected.length; index += 1) {
    const want = expected[index] as string;
    const got = actual[index] as string;
    if (want.startsWith(":")) {
      params[want.slice(1)] = decodeURIComponent(got);
    } else if (want !== got) {
      return null;
    }
  }
  return params;
}

/**
 * Read a JSON body under a hard cap. `Content-Length` is checked first so an oversized body is
 * refused without being read at all; the running total is checked as well, because a chunked
 * request has no declared length and would otherwise stream past the cap.
 */
async function readJsonBody(request: IncomingMessage): Promise<unknown> {
  const declared = request.headers["content-length"];
  if (declared !== undefined) {
    const length = Number(declared);
    if (!Number.isFinite(length) || length < 0) throw HttpError.invalid("bad content-length");
    if (length > MAX_JSON_BODY_BYTES) {
      throw new HttpError(413, "capacity", "request body too large");
    }
  }

  const chunks: Buffer[] = [];
  let total = 0;
  for await (const chunk of request) {
    const buffer = chunk as Buffer;
    total += buffer.length;
    if (total > MAX_JSON_BODY_BYTES) {
      request.destroy();
      throw new HttpError(413, "capacity", "request body too large");
    }
    chunks.push(buffer);
  }
  if (total === 0) return undefined;

  const text = Buffer.concat(chunks).toString("utf8");
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw HttpError.invalid("body is not JSON");
  }
}

export interface ServerDependencies {
  readonly config: Config;
  readonly routes: readonly Route[];
  /** Injected so tests can observe a rejection without a log sink. */
  readonly onError?: (error: unknown, context: { method: string; path: string }) => void;
}

export function createHttpServer(dependencies: ServerDependencies): Server {
  const { config, routes } = dependencies;
  const onError =
    dependencies.onError ??
    ((error: unknown) => {
      // Codes and paths only. Never a header, a cookie, a token or a body.
      console.error(error instanceof Error ? error.message : "request failed");
    });

  return createServer((request, response) => {
    void handle(request, response, routes, config, onError);
  });
}

async function handle(
  request: IncomingMessage,
  response: ServerResponse,
  routes: readonly Route[],
  config: Config,
  onError: (error: unknown, context: { method: string; path: string }) => void,
): Promise<void> {
  const method = request.method ?? "GET";
  const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);

  const baseHeaders: Record<string, string> = {
    // Sessions and share content must not be cached anywhere, by anyone.
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
  };

  // Exact-origin echo with credentials. A wildcard would be incompatible with cookies and is
  // refused at configuration time.
  const origin = request.headers.origin;
  if (typeof origin === "string" && config.allowedOrigins.includes(origin)) {
    baseHeaders["access-control-allow-origin"] = origin;
    baseHeaders["access-control-allow-credentials"] = "true";
    baseHeaders["vary"] = "origin";
  }

  try {
    if (method === "OPTIONS") {
      response.writeHead(204, {
        ...baseHeaders,
        "access-control-allow-methods": "GET, POST, DELETE, OPTIONS",
        "access-control-allow-headers": `content-type, ${config.csrfHeaderName}`,
        "access-control-max-age": "600",
      });
      response.end();
      return;
    }

    const cookies = parseCookies(request.headers.cookie);
    const body = method === "POST" || method === "PATCH" ? await readJsonBody(request) : undefined;
    const context: RequestContext = { method, url, headers: request.headers, cookies, body };

    for (const route of routes) {
      const params = matchRoute(route, method, url.pathname);
      if (params === null) continue;

      const result = await route.handler(context, params);
      const headers: Record<string, string> = { ...baseHeaders, ...(result.headers ?? {}) };
      if (result.body !== undefined) headers["content-type"] = "application/json; charset=utf-8";
      if (result.cookies !== undefined && result.cookies.length > 0) {
        headers["set-cookie"] = result.cookies as unknown as string;
      }
      response.writeHead(result.status ?? 200, headers);
      response.end(result.body === undefined ? undefined : JSON.stringify(result.body));
      return;
    }

    throw HttpError.notFound();
  } catch (error) {
    const httpError =
      error instanceof HttpError
        ? error
        : error instanceof Error && "status" in error && "code" in error
          ? new HttpError(
              Number((error as { status: unknown }).status),
              String((error as { code: unknown }).code),
              error.message,
            )
          : new HttpError(500, "invalid_frame", "internal error");

    onError(error, { method, path: url.pathname });
    response.writeHead(httpError.status, {
      ...baseHeaders,
      "content-type": "application/json; charset=utf-8",
    });
    // The code is the whole message. The reason stays in the log.
    response.end(JSON.stringify({ error: httpError.code }));
  }
}
