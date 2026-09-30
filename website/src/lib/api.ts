/**
 * The backend API client.
 *
 * Two things it always does, because getting either wrong is a silent failure:
 *
 *   * `credentials: "include"`, so the session cookie travels. The website and the API share an
 *     origin in production; in development they do not, and the backend echoes the exact origin.
 *   * Echoes the CSRF token from the readable cookie into a header on every write. The backend
 *     checks that header against the digest stored against the session *and* checks the Origin —
 *     the cookie alone is never accepted, which is why the header is not optional here.
 */

const BASE_URL = process.env.NEXT_PUBLIC_API_BASE_URL ?? "http://127.0.0.1:8081";

export const CSRF_COOKIE_NAME = "swiftterm_csrf";
export const CSRF_HEADER_NAME = "x-swiftterm-csrf";

/** An allowlisted protocol code, plus the HTTP status that carried it. */
export class ApiError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string) {
    super(code);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
  }

  /** A message safe to show a person, derived only from the allowlisted code. */
  get messageForUser(): string {
    switch (this.code) {
      case "unauthorized":
        return "Your session has ended. Sign in again.";
      case "session_ended":
        return "Your session has ended. Sign in again.";
      case "rate_limited":
        return "Too many attempts. Wait a moment and try again.";
      case "capacity":
        return "That request was too large.";
      default:
        return "Something went wrong. Try again.";
    }
  }
}

export function readCsrfToken(): string | null {
  if (typeof document === "undefined") return null;
  for (const pair of document.cookie.split(";")) {
    const trimmed = pair.trim();
    if (trimmed.startsWith(`${CSRF_COOKIE_NAME}=`)) {
      return decodeURIComponent(trimmed.slice(CSRF_COOKIE_NAME.length + 1));
    }
  }
  return null;
}

export interface ApiRequest {
  readonly method?: string;
  readonly body?: unknown;
}

export async function apiFetch<T>(path: string, request: ApiRequest = {}): Promise<T> {
  const method = request.method ?? "GET";
  const headers: Record<string, string> = {};

  if (request.body !== undefined) headers["content-type"] = "application/json";
  if (method !== "GET") {
    const csrf = readCsrfToken();
    if (csrf !== null) headers[CSRF_HEADER_NAME] = csrf;
  }

  const init: RequestInit = { method, headers, credentials: "include" };
  if (request.body !== undefined) init.body = JSON.stringify(request.body);

  const response = await fetch(`${BASE_URL}${path}`, init);

  if (response.status === 204) return undefined as T;

  const text = await response.text();
  let payload: unknown;
  try {
    payload = text === "" ? undefined : JSON.parse(text);
  } catch {
    throw new ApiError(response.status, "invalid_frame");
  }

  if (!response.ok) {
    const code =
      payload !== null && typeof payload === "object" && "error" in payload
        ? String((payload as { error: unknown }).error)
        : "invalid_frame";
    throw new ApiError(response.status, code);
  }

  return payload as T;
}
