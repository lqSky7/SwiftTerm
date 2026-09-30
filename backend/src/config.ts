/**
 * Configuration, loaded once and validated at startup.
 *
 * The rule from the handoff is that missing production inputs fail startup, and that a localhost
 * fixture can never become a production auth bypass. So there is no fallback secret, no default
 * issuer and no "development mode" that skips verification: the only way to run without real
 * configuration is to set `SWIFTTERM_TEST_FIXTURES`, which is refused outright when
 * `NODE_ENV=production`.
 */

export interface Config {
  readonly databaseUrl: string;
  readonly oidcIssuer: string;
  readonly oidcAudience: string;
  readonly oidcJwksUri: string;
  readonly allowedOrigins: readonly string[];
  readonly host: string;
  readonly port: number;
  /** Absolute session lifetime. Capped at 24 hours, which the database CHECK also enforces. */
  readonly sessionTtlHours: number;
  /**
   * Open streams one account may have at once.
   *
   * Enforced in `swiftterm.create_live_session` rather than here, because it has to hold across
   * relay instances and across a restart. This value is passed in so it is one number in one place.
   */
  readonly maxLiveStreamsPerAccount: number;
  readonly cookieName: string;
  readonly csrfCookieName: string;
  readonly csrfHeaderName: string;
  /**
   * `Lax` when the website and the API share an origin — which is the design the handoff
   * specifies. `None` is required when they do not, because a `Lax` cookie is not sent on a
   * cross-site request at all, so the session would silently never arrive. It is not a
   * weakening of CSRF defence: the primary controls are the Origin allowlist and the CSRF
   * header digest, both of which are checked on every write regardless of this value.
   */
  readonly cookieSameSite: "Lax" | "Strict" | "None";
  /** Secure cookies require HTTPS. Off only for plain-HTTP local development. */
  readonly secureCookies: boolean;
  /** True only when the operator explicitly opted into test fixtures. */
  readonly testFixtures: boolean;
}

export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ConfigError";
  }
}

const MAX_SESSION_HOURS = 24;

function required(env: NodeJS.ProcessEnv, name: string): string {
  const value = env[name];
  if (value === undefined || value.trim() === "") {
    throw new ConfigError(`${name} is required`);
  }
  return value;
}

function optionalNumber(env: NodeJS.ProcessEnv, name: string, fallback: number): number {
  const raw = env[name];
  if (raw === undefined || raw.trim() === "") return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value <= 0) {
    throw new ConfigError(`${name} must be a positive integer`);
  }
  return value;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const isProduction = env.NODE_ENV === "production";
  const testFixtures = env.SWIFTTERM_TEST_FIXTURES === "1";

  if (testFixtures && isProduction) {
    throw new ConfigError(
      "SWIFTTERM_TEST_FIXTURES cannot be enabled with NODE_ENV=production: test fixtures are not " +
        "an authentication bypass for a deployed service",
    );
  }

  const issuer = required(env, "OIDC_ISSUER");
  const audience = required(env, "OIDC_AUDIENCE");
  const jwksUri = required(env, "OIDC_JWKS_URI");

  // An issuer that is not HTTPS cannot be trusted, and a JWKS that does not live under the issuer
  // is a second source of truth for who may sign a token.
  if (!issuer.startsWith("https://") && !testFixtures) {
    throw new ConfigError("OIDC_ISSUER must be an https URL");
  }
  if (!jwksUri.startsWith(issuer.replace(/\/$/, "")) && !testFixtures) {
    throw new ConfigError("OIDC_JWKS_URI must live under OIDC_ISSUER");
  }

  const origins = required(env, "ALLOWED_ORIGINS")
    .split(",")
    .map((origin) => origin.trim())
    .filter((origin) => origin !== "");
  if (origins.length === 0) {
    throw new ConfigError("ALLOWED_ORIGINS must list at least one exact origin");
  }
  for (const origin of origins) {
    if (origin === "*") {
      throw new ConfigError("ALLOWED_ORIGINS must not contain a wildcard");
    }
  }

  const sessionTtlHours = Math.min(
    optionalNumber(env, "SESSION_TTL_HOURS", MAX_SESSION_HOURS),
    MAX_SESSION_HOURS,
  );

  return {
    databaseUrl: required(env, "DATABASE_URL"),
    oidcIssuer: issuer.replace(/\/$/, ""),
    oidcAudience: audience,
    oidcJwksUri: jwksUri,
    allowedOrigins: origins,
    host: env.HOST?.trim() || "127.0.0.1",
    port: optionalNumber(env, "PORT", 8081),
    sessionTtlHours,
    maxLiveStreamsPerAccount: optionalNumber(env, "MAX_LIVE_STREAMS_PER_ACCOUNT", 5),
    cookieName: env.SESSION_COOKIE_NAME?.trim() || "swiftterm_session",
    csrfCookieName: env.CSRF_COOKIE_NAME?.trim() || "swiftterm_csrf",
    csrfHeaderName: env.CSRF_HEADER_NAME?.trim() || "x-swiftterm-csrf",
    cookieSameSite: parseSameSite(env.COOKIE_SAME_SITE),
    secureCookies: env.SECURE_COOKIES === "0" ? false : true,
    testFixtures,
  };
}

/** Defaults to `Lax`, which is correct whenever the site and the API share an origin. */
function parseSameSite(value: string | undefined): "Lax" | "Strict" | "None" {
  switch ((value ?? "Lax").trim().toLowerCase()) {
    case "none":
      return "None";
    case "strict":
      return "Strict";
    default:
      return "Lax";
  }
}
