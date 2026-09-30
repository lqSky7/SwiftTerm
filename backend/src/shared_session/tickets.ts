/**
 * One-use socket tickets.
 *
 * The socket handshake needs a credential that is *not* the session cookie and *not* the device
 * token, because a WebSocket upgrade carries neither a CSRF header nor a usable header set in every
 * client. So the HTTP API mints a short-lived ticket, and the socket presents it in its first
 * frame.
 *
 * Four properties, and each one is why a simpler design was rejected:
 *
 *   * **Only the hash is held.** The relay stores SHA-256 of the ticket, never the ticket. A relay
 *     that is compromised or whose memory is dumped does not hand out working credentials — the
 *     same reason `web_sessions` and `devices` store digests.
 *   * **One use, consumed atomically.** `consume` deletes before it returns, so two sockets racing
 *     the same ticket cannot both win. This is why the store is a map of hashes rather than a list
 *     to scan and mark.
 *   * **Thirty seconds.** A ticket exists to cross one network round trip. Anything longer is a
 *     credential sitting in a log or a browser history for no benefit.
 *   * **Never in a URL.** The ticket travels in the first frame, not the query string, because a
 *     query string ends up in access logs, `Referer` headers and shell history. The relay's own
 *     logs must not be a place a credential can be read from.
 *
 * The store is bounded, and it evicts rather than grows. A flood of tickets must not be able to
 * make the relay allocate without limit — the same rule the rest of the frame path follows.
 */

import { createHash, randomBytes, timingSafeEqual } from "node:crypto";

/** A ticket is 32 random bytes. Short enough to type nowhere, long enough to not be guessable. */
export const TICKET_BYTES = 32;

/** The whole life of a ticket. See the note above on why this is not configurable upward. */
export const TICKET_TTL_MS = 30_000;

/** Which end of the socket this ticket admits. A browser may never be a publisher. */
export type SocketRole = "publisher" | "viewer";

export interface TicketGrant {
  readonly role: SocketRole;
  readonly sessionId: string;
  /** The account the ticket was minted for. Checked again on every admission decision. */
  readonly accountId: string;
  /** For a publisher, the device the pane belongs to. Absent for a viewer. */
  readonly deviceId?: string;
  /**
   * For a publisher, the lease the route installed when it minted this ticket. The socket layer
   * hands it back on disconnect so the caller can release the lease, and it travels with the ticket
   * rather than being looked up because a publisher that reconnected between mint and connect must
   * release the lease *it* holds, not whatever the database holds now.
   */
  readonly leaseToken?: string;
  /**
   * The epoch the ticket was minted against. A ticket for a superseded epoch is refused even if it
   * is otherwise valid and unexpired, so a reconnect cannot resurrect a fenced publisher.
   */
  readonly epoch: string;
}

interface Entry {
  readonly grant: TicketGrant;
  readonly expiresAt: number;
}

export interface TicketStoreOptions {
  /** Hard cap on live tickets. Eviction removes the nearest to expiry first. */
  readonly capacity?: number;
  /** Injectable so tests can advance time without sleeping. */
  readonly now?: () => number;
}

export class TicketStore {
  readonly #entries = new Map<string, Entry>();
  readonly #capacity: number;
  readonly #now: () => number;

  constructor(options: TicketStoreOptions = {}) {
    this.#capacity = options.capacity ?? 4096;
    this.#now = options.now ?? (() => Date.now());
  }

  get size(): number {
    return this.#entries.size;
  }

  /**
   * Mint a ticket and return it in the clear. This is the only moment it exists outside the
   * caller's response — the store keeps the hash and nothing else.
   */
  issue(grant: TicketGrant): { ticket: string; expiresAt: number } {
    if (grant.role === "publisher" && (grant.deviceId === undefined || grant.deviceId === "")) {
      // A publisher with no device cannot be admitted, and failing here means the bug surfaces at
      // issue time rather than as a socket that connects and is immediately dropped.
      throw new Error("a publisher ticket requires a device");
    }

    this.#evictIfNeeded();

    const ticket = randomBytes(TICKET_BYTES).toString("base64url");
    const expiresAt = this.#now() + TICKET_TTL_MS;
    this.#entries.set(hash(ticket), { grant, expiresAt });
    return { ticket, expiresAt };
  }

  /**
   * Spend a ticket. Returns the grant exactly once; every later call with the same ticket returns
   * `null`. Deleting before returning is what makes it atomic — there is no window in which two
   * callers both see the entry.
   */
  consume(ticket: string): TicketGrant | null {
    const key = hash(ticket);
    const entry = this.#entries.get(key);
    if (entry === undefined) return null;
    this.#entries.delete(key);

    if (entry.expiresAt <= this.#now()) return null;
    return entry.grant;
  }

  /** Drop everything already expired. Called opportunistically; the relay never scans on a timer. */
  sweep(): number {
    const now = this.#now();
    let removed = 0;
    for (const [key, entry] of this.#entries) {
      if (entry.expiresAt <= now) {
        this.#entries.delete(key);
        removed += 1;
      }
    }
    return removed;
  }

  #evictIfNeeded(): void {
    this.sweep();
    if (this.#entries.size < this.#capacity) return;

    // Still full after sweeping, so evict the nearest to expiry. Refusing to issue would turn a
    // flood into an outage for legitimate users; evicting costs at most an expired-in-a-moment
    // ticket.
    let oldestKey: string | null = null;
    let oldest = Number.POSITIVE_INFINITY;
    for (const [key, entry] of this.#entries) {
      if (entry.expiresAt < oldest) {
        oldest = entry.expiresAt;
        oldestKey = key;
      }
    }
    if (oldestKey !== null) this.#entries.delete(oldestKey);
  }
}

function hash(ticket: string): string {
  return createHash("sha256").update(ticket, "utf8").digest("hex");
}

/** Constant-time compare for a presented hash, where a plain `===` would be a timing oracle. */
export function hashesEqual(a: string, b: string): boolean {
  const left = Buffer.from(a, "utf8");
  const right = Buffer.from(b, "utf8");
  return left.length === right.length && timingSafeEqual(left, right);
}
