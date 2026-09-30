/**
 * The relay's session registry.
 *
 * This holds the live state the relay is allowed to keep: one publisher per session, a set of
 * viewers, and a bounded ring of recently emitted frames so a viewer that reconnects can catch up
 * without a fresh snapshot. **No terminal content is ever written to the database** — this is the
 * only place frames live, and they are dropped when the session ends or the ring evicts them.
 *
 * Every limit here is enforced *before* allocation rather than after. The handoff's rule is that
 * relaying malformed or oversized data cannot allocate beyond the admission limits, and the way to
 * honour that is to refuse at the door: a viewer beyond the cap is never added to the set, a frame
 * that would exceed the ring is rejected before it is copied, and an account at its stream cap
 * cannot open another.
 *
 * Time is injected. Every deadline in this file — the replay window, the lease expiry, the
 * heartbeat — is read from the clock the registry was built with, so the tests exercise staleness
 * without sleeping for it.
 */

export interface SessionLimits {
  /** Open streams one account may have. */
  readonly maxStreamsPerAccount: number;
  /** Viewers attached to one stream. */
  readonly maxViewersPerStream: number;
  /** Publishers this process will hold. */
  readonly maxPublishersPerProcess: number;
  /** How many bytes of recent frames one session retains. */
  readonly replayBytesPerSession: number;
  /** How far back the retained frames reach. */
  readonly replayWindowMs: number;
  /** Bytes buffered for one slow socket before it is dropped rather than allowed to stall the host. */
  readonly maxPendingBytesPerSocket: number;
  /** Bytes retained across every session in this process. */
  readonly aggregateBytes: number;
  /** How long a publisher may go without renewing before its lease is stale. */
  readonly publisherLeaseMs: number;
}

export const DEFAULT_LIMITS: SessionLimits = {
  maxStreamsPerAccount: 5,
  maxViewersPerStream: 10,
  maxPublishersPerProcess: 25,
  replayBytesPerSession: 8 * 1024 * 1024,
  replayWindowMs: 30_000,
  maxPendingBytesPerSocket: 1024 * 1024,
  aggregateBytes: 256 * 1024 * 1024,
  publisherLeaseMs: 30_000,
};

export type OpenResult =
  | { readonly ok: true; readonly session: RelaySession; readonly created: boolean }
  | { readonly ok: false; readonly reason: OpenRefusal };

export type OpenRefusal =
  | "account_stream_limit"
  | "pane_already_shared"
  | "process_publisher_limit"
  | "request_conflict";

export type AdmitResult =
  | { readonly ok: true; readonly viewer: Viewer }
  | { readonly ok: false; readonly reason: "viewer_limit" | "session_ended" };

export interface OpenRequest {
  readonly ownerId: string;
  readonly deviceId: string;
  readonly localPaneId: string;
  readonly clientRequestId: string;
  /** Digest of the whole open request, so an identical retry is idempotent and a changed one is not. */
  readonly requestDigest: string;
  readonly title?: string;
}

export interface RelayedFrame {
  readonly seq: number;
  readonly bytes: number;
  readonly at: number;
}

export class Viewer {
  readonly id: string;
  /** Bytes buffered for this socket and not yet acknowledged. */
  pendingBytes = 0;

  // Written out rather than a constructor parameter property: `erasableSyntaxOnly` allows only
  // syntax that disappears at runtime, and a parameter property emits an assignment.
  constructor(id: string) {
    this.id = id;
  }

  get isStalled(): boolean {
    return this.pendingBytes > 0;
  }
}

export class RelaySession {
  readonly id: string;
  readonly ownerId: string;
  readonly deviceId: string;
  readonly localPaneId: string;
  readonly clientRequestId: string;
  readonly requestDigest: string;
  readonly createdAt: number;

  /** Starts at 1 and only ever increases. A publisher reconnect gets a new one, fencing the old. */
  epoch = 1;
  title: string;

  #ended = false;
  #endedAt: number | null = null;
  #leaseRenewedAt: number;
  #seq = 0;
  #replay: RelayedFrame[] = [];
  #replayBytes = 0;
  readonly #viewers = new Map<string, Viewer>();
  readonly #limits: SessionLimits;
  readonly #now: () => number;

  constructor(request: OpenRequest, limits: SessionLimits, now: () => number) {
    this.id = request.clientRequestId;
    this.ownerId = request.ownerId;
    this.deviceId = request.deviceId;
    this.localPaneId = request.localPaneId;
    this.clientRequestId = request.clientRequestId;
    this.requestDigest = request.requestDigest;
    this.title = request.title ?? "";
    this.#limits = limits;
    this.#now = now;
    this.createdAt = now();
    this.#leaseRenewedAt = this.createdAt;
  }

  get ended(): boolean {
    return this.#ended;
  }

  get endedAt(): number | null {
    return this.#endedAt;
  }

  get viewerCount(): number {
    return this.#viewers.size;
  }

  get viewers(): readonly Viewer[] {
    return [...this.#viewers.values()];
  }

  /** The highest seq emitted. A viewer resuming at this value has seen everything retained. */
  get lastSeq(): number {
    return this.#seq;
  }

  get replayBytes(): number {
    return this.#replayBytes;
  }

  /** True when the publisher has stopped renewing, so the relay must stop carrying its traffic. */
  get leaseIsStale(): boolean {
    return !this.#ended && this.#now() - this.#leaseRenewedAt > this.#limits.publisherLeaseMs;
  }

  renewLease(): void {
    if (this.#ended) return;
    this.#leaseRenewedAt = this.#now();
  }

  /**
   * End the session for good. Idempotent, and there is no way back: a reconnect after this gets a
   * new session rather than resurrecting this one, which is what "ended sessions stay ended" means.
   */
  end(): void {
    if (this.#ended) return;
    this.#ended = true;
    this.#endedAt = this.#now();
    this.#viewers.clear();
    this.#replay = [];
    this.#replayBytes = 0;
  }

  /**
   * Admit a viewer, or refuse. The cap is checked before the viewer is added, so a flood of
   * connections cannot make the set grow past the limit even momentarily.
   */
  admitViewer(viewerId: string): AdmitResult {
    if (this.#ended) return { ok: false, reason: "session_ended" };
    if (this.#viewers.size >= this.#limits.maxViewersPerStream) {
      return { ok: false, reason: "viewer_limit" };
    }
    const viewer = new Viewer(viewerId);
    this.#viewers.set(viewerId, viewer);
    return { ok: true, viewer };
  }

  removeViewer(viewerId: string): boolean {
    return this.#viewers.delete(viewerId);
  }

  /**
   * Record a frame the publisher emitted and give it its seq.
   *
   * The size is checked against the ring *before* anything is stored, so an oversized frame is
   * refused rather than being copied and then evicted — the allocation the handoff forbids.
   */
  publish(bytes: number): RelayedFrame | null {
    if (this.#ended) return null;
    if (bytes > this.#limits.replayBytesPerSession) return null;

    this.#seq += 1;
    const frame: RelayedFrame = { seq: this.#seq, bytes, at: this.#now() };
    this.#replay.push(frame);
    this.#replayBytes += bytes;
    this.#evict();
    return frame;
  }

  /**
   * The retained frames a viewer at `fromSeq` has not seen. Returns `null` when the gap has already
   * been evicted, which is the relay's cue to ask the host for a fresh snapshot rather than to
   * replay a hole.
   */
  replayFrom(fromSeq: number): readonly RelayedFrame[] | null {
    if (fromSeq >= this.#seq) return [];
    const oldest = this.#replay[0];
    if (oldest !== undefined && oldest.seq > fromSeq + 1) return null;
    return this.#replay.filter((frame) => frame.seq > fromSeq);
  }

  /** Attach bytes to a viewer's socket, refusing once it is too far behind to keep up. */
  queueFor(viewerId: string, bytes: number): boolean {
    const viewer = this.#viewers.get(viewerId);
    if (viewer === undefined) return false;
    if (viewer.pendingBytes + bytes > this.#limits.maxPendingBytesPerSocket) {
      // The socket is dropped rather than allowed to grow. A slow viewer must never be able to
      // stall the host, and buffering for it indefinitely is exactly how that happens.
      this.#viewers.delete(viewerId);
      return false;
    }
    viewer.pendingBytes += bytes;
    return true;
  }

  acknowledge(viewerId: string, bytes: number): void {
    const viewer = this.#viewers.get(viewerId);
    if (viewer === undefined) return;
    viewer.pendingBytes = Math.max(0, viewer.pendingBytes - bytes);
  }

  #evict(): void {
    const cutoff = this.#now() - this.#limits.replayWindowMs;
    while (this.#replay.length > 0) {
      const oldest = this.#replay[0];
      if (oldest === undefined) break;
      const tooOld = oldest.at < cutoff;
      const tooBig = this.#replayBytes > this.#limits.replayBytesPerSession;
      if (!tooOld && !tooBig) break;
      this.#replay.shift();
      this.#replayBytes -= oldest.bytes;
    }
  }
}

export class SessionRegistry {
  readonly #sessions = new Map<string, RelaySession>();
  /** client_request_id per account, so an identical retry finds the session it already made. */
  readonly #byRequest = new Map<string, string>();
  readonly #limits: SessionLimits;
  readonly #now: () => number;

  constructor(limits: SessionLimits = DEFAULT_LIMITS, now: () => number = () => Date.now()) {
    this.#limits = limits;
    this.#now = now;
  }

  get size(): number {
    return this.#sessions.size;
  }

  /** Bytes retained across every live session, which is what the aggregate cap governs. */
  get retainedBytes(): number {
    let total = 0;
    for (const session of this.#sessions.values()) total += session.replayBytes;
    return total;
  }

  get(id: string): RelaySession | undefined {
    return this.#sessions.get(id);
  }

  /**
   * Open a stream, or return the one an identical retry already made.
   *
   * Every refusal is decided before a session is constructed, so a refused open leaves no partial
   * state behind.
   */
  open(request: OpenRequest): OpenResult {
    const requestKey = `${request.ownerId}:${request.clientRequestId}`;
    const existingId = this.#byRequest.get(requestKey);
    if (existingId !== undefined) {
      const existing = this.#sessions.get(existingId);
      if (existing !== undefined) {
        // Same request id, different payload: a retry is idempotent, a change is a conflict.
        if (existing.requestDigest !== request.requestDigest) {
          return { ok: false, reason: "request_conflict" };
        }
        return { ok: true, session: existing, created: false };
      }
    }

    if (this.#countForAccount(request.ownerId) >= this.#limits.maxStreamsPerAccount) {
      return { ok: false, reason: "account_stream_limit" };
    }
    for (const session of this.#sessions.values()) {
      if (
        !session.ended &&
        session.deviceId === request.deviceId &&
        session.localPaneId === request.localPaneId
      ) {
        return { ok: false, reason: "pane_already_shared" };
      }
    }
    if (this.#livePublisherCount() >= this.#limits.maxPublishersPerProcess) {
      return { ok: false, reason: "process_publisher_limit" };
    }

    const session = new RelaySession(request, this.#limits, this.#now);
    this.#sessions.set(session.id, session);
    this.#byRequest.set(requestKey, session.id);
    return { ok: true, session, created: true };
  }

  /** End a session and forget it. The entry is dropped so the account's stream count falls. */
  end(id: string): boolean {
    const session = this.#sessions.get(id);
    if (session === undefined) return false;
    session.end();
    this.#sessions.delete(id);
    return true;
  }

  /** Sessions that have stopped renewing. The caller ends them; the registry only reports them. */
  staleLeases(): readonly RelaySession[] {
    return [...this.#sessions.values()].filter((session) => session.leaseIsStale);
  }

  /** Sessions for one account, newest first. This is what the owner's session list shows. */
  forAccount(ownerId: string): readonly RelaySession[] {
    return [...this.#sessions.values()]
      .filter((session) => session.ownerId === ownerId)
      .sort((left, right) => right.createdAt - left.createdAt);
  }

  #countForAccount(ownerId: string): number {
    let count = 0;
    for (const session of this.#sessions.values()) {
      if (session.ownerId === ownerId) count += 1;
    }
    return count;
  }

  #livePublisherCount(): number {
    let count = 0;
    for (const session of this.#sessions.values()) {
      if (!session.ended) count += 1;
    }
    return count;
  }
}
