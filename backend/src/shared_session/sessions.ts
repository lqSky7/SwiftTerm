/**
 * The relay's live session state.
 *
 * This holds the state the relay is allowed to keep in memory: who is publishing, which viewers are
 * attached, and a bounded ring of recently emitted frames so a viewer that reconnects can catch up
 * without a fresh snapshot. **No terminal content is ever written to the database** — this is the
 * only place frames live, and they are dropped when the session ends or the ring evicts them.
 *
 * **Admission limits are not here.** One open stream per pane, the per-account stream cap and
 * idempotency on `client_request_id` all live in `swiftterm.create_live_session`, because they have
 * to hold across relay instances and across a relay restart. Keeping a second copy in memory would
 * give the same rule two implementations and two answers, and the in-memory one would be wrong after
 * a restart. What remains here is what is genuinely process-local: how many publishers *this* process
 * will carry, how many bytes it will retain, and how many viewers one stream may attach.
 *
 * A session is keyed by its **durable UUID** — the same value in the socket path `/live/<uuid>` and
 * the primary key of `live_sessions`. One identity, so a reconnect after a relay restart lands on
 * the same session rather than minting a parallel one.
 *
 * Every limit is enforced *before* allocation rather than after: a viewer beyond the cap is never
 * added to the set, a frame that would exceed the ring is rejected before it is copied, and a
 * process at its publisher cap cannot open another.
 *
 * Time is injected. Every deadline in this file — the replay window, the lease expiry — is read from
 * the clock the registry was built with, so the tests exercise staleness without sleeping for it.
 */

export interface SessionLimits {
  /** Viewers attached to one stream. A process-local bound: each viewer is a socket it holds. */
  readonly maxViewersPerStream: number;
  /** Publishers this process will carry. The relay's own memory budget, not an account's. */
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
  | { readonly ok: false; readonly reason: "process_publisher_limit" };

export type AdmitResult =
  | { readonly ok: true; readonly viewer: Viewer }
  | { readonly ok: false; readonly reason: "viewer_limit" | "session_ended" };

export interface OpenRequest {
  /** The durable session UUID. The socket path and the database row share this value. */
  readonly sessionId: string;
  readonly ownerId: string;
  readonly deviceId: string;
  readonly localPaneId: string;
  /** The publisher epoch the database currently holds. 0 until a publisher is first admitted. */
  readonly publisherEpoch: number;
  readonly title?: string;
}

export interface RelayedFrame {
  /** The publisher's own sequence number. Several frames may share one, as a snapshot's do. */
  readonly seq: number;
  readonly bytes: number;
  readonly at: number;
  /** The frame exactly as the publisher sent it. Forwarded verbatim; never re-encoded. */
  readonly payload: string;
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
  readonly createdAt: number;

  title: string;

  #epoch: number;
  #ended = false;
  #endedAt: number | null = null;
  #leaseRenewedAt: number;
  #seq = 0;
  #replay: RelayedFrame[] = [];
  #replayBytes = 0;
  /**
   * The `hello` at the head of the stream, kept while it is still retained.
   *
   * It is the only frame that carries the epoch and geometry, so it is what lets a joining viewer
   * learn enough to ask for a resume. Once the ring evicts it the history no longer starts at the
   * stream's beginning, and a viewer with nothing applied must be told to resync instead of being
   * handed a mid-stream tail.
   */
  #streamStart: RelayedFrame | null = null;
  readonly #viewers = new Map<string, Viewer>();
  readonly #limits: SessionLimits;
  readonly #now: () => number;

  constructor(request: OpenRequest, limits: SessionLimits, now: () => number) {
    this.id = request.sessionId;
    this.ownerId = request.ownerId;
    this.deviceId = request.deviceId;
    this.localPaneId = request.localPaneId;
    this.title = request.title ?? "";
    this.#limits = limits;
    this.#now = now;
    this.createdAt = now();
    this.#leaseRenewedAt = this.createdAt;
    this.#epoch = request.publisherEpoch;
  }

  /**
   * The publisher generation, which is the database's `publisher_epoch`.
   *
   * The two must be the same number: a ticket carries this value and the socket layer refuses a
   * ticket whose epoch does not match, so a relay that counted independently would refuse its own
   * publisher's ticket the first time the database incremented.
   */
  get epoch(): number {
    return this.#epoch;
  }

  /**
   * Move to a newer publisher generation. Only ever forward — an epoch that went backwards would
   * re-admit a generation the database has already fenced out.
   */
  adoptEpoch(epoch: number): void {
    if (epoch > this.#epoch) this.#epoch = epoch;
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
    this.#streamStart = null;
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
   * Record a frame the publisher emitted, at the seq the publisher gave it.
   *
   * Returns `false` when the frame is refused, and nothing is stored in that case — the size is
   * checked against the ring *before* the frame is retained, which is the allocation the handoff
   * forbids. `seq` is non-decreasing rather than strictly increasing because a snapshot's chunks and
   * its end frame all belong to the same sequence position; a publisher that went backwards is
   * refused, since replaying it would deliver frames out of order.
   */
  publish(seq: number, bytes: number, payload: string): boolean {
    if (this.#ended) return false;
    if (bytes > this.#limits.replayBytesPerSession) return false;
    if (seq < this.#seq) return false;

    const frame: RelayedFrame = { seq, bytes, at: this.#now(), payload };
    this.#replay.push(frame);
    this.#replayBytes += bytes;
    if (seq > this.#seq) this.#seq = seq;
    // The stream start is seq 0, which no snapshot or damage frame can use: a snapshot's seq is the
    // position it establishes and a damage frame's seq is at least 1.
    if (seq === 0 && this.#streamStart === null) this.#streamStart = frame;
    this.#evict();
    return true;
  }

  /** The retained `hello`, or `null` once the ring has evicted it. */
  streamStart(): RelayedFrame | null {
    return this.#streamStart;
  }

  /**
   * The retained frames a viewer at `fromSeq` has not seen, or `null` when a replay would be a lie.
   *
   * `null` means "ask the host for a fresh snapshot", and there are two ways to earn it: the gap has
   * been evicted, or the viewer has applied nothing and the retained history no longer starts at the
   * stream's beginning. A viewer that has never seen a snapshot cannot be handed deltas, because
   * there is nothing for them to apply to.
   */
  replayFrom(fromSeq: number): readonly RelayedFrame[] | null {
    // An ended session cannot be caught up: there is no host to send a snapshot and nothing left to
    // replay. The socket layer refuses an ended session at admission, so this is the defensive
    // answer rather than the reachable one — stated explicitly so it is a rule and not an accident
    // of the ring having been cleared.
    if (this.#ended) return null;
    if (fromSeq >= this.#seq) return [];
    const first = this.#replay[0];
    if (first === undefined) return null;
    if (fromSeq === 0) {
      if (this.#streamStart === null) return null;
      // Everything, including the stream start, which sits at seq 0 and would otherwise be filtered
      // out by the `seq > fromSeq` test below.
      return [...this.#replay];
    }
    if (first.seq > fromSeq + 1) return null;
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
      // Once the head is gone the history no longer begins at the stream's start, and a viewer with
      // nothing applied can no longer be caught up by replay.
      if (this.#streamStart === oldest) this.#streamStart = null;
    }
  }
}

export class SessionRegistry {
  readonly #sessions = new Map<string, RelaySession>();
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
   * Register a session this process will relay, or return the one already registered.
   *
   * Idempotent on the session id, so the caller can call it on every request that needs the session
   * to exist in memory without tracking whether it already did. The only refusal is this process's
   * own publisher budget: everything else was decided by the database before the caller got here.
   */
  open(request: OpenRequest): OpenResult {
    const existing = this.#sessions.get(request.sessionId);
    if (existing !== undefined) {
      // The epoch may have moved on in the database while this session sat in memory.
      existing.adoptEpoch(request.publisherEpoch);
      return { ok: true, session: existing, created: false };
    }

    if (this.#livePublisherCount() >= this.#limits.maxPublishersPerProcess) {
      return { ok: false, reason: "process_publisher_limit" };
    }

    const session = new RelaySession(request, this.#limits, this.#now);
    this.#sessions.set(session.id, session);
    return { ok: true, session, created: true };
  }

  /** End a session and forget it. The entry is dropped so the process's publisher count falls. */
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

  #livePublisherCount(): number {
    let count = 0;
    for (const session of this.#sessions.values()) {
      if (!session.ended) count += 1;
    }
    return count;
  }
}
