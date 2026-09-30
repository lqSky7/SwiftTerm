/**
 * The relay session registry.
 *
 * What this file covers is what is genuinely process-local: the replay ring, the viewer cap, the
 * byte budgets, the lease staleness and the fact that an ended session stays ended. The admission
 * limits that used to live here — one stream per pane, the per-account cap, request idempotency —
 * now live in `swiftterm.create_live_session` and are covered against the real database in
 * `live.test.ts`, because they have to hold across relay instances and a copy in memory would be
 * wrong after a restart.
 *
 * The clock is injected everywhere, so the replay window and the lease expiry are exercised by
 * advancing time rather than by sleeping for thirty seconds.
 */

import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { describe, it } from "node:test";

import {
  DEFAULT_LIMITS,
  SessionRegistry,
  type OpenRequest,
  type SessionLimits,
} from "../src/shared_session/sessions.ts";

function registry(
  overrides: Partial<SessionLimits> = {},
  now: () => number = () => 1_000,
): SessionRegistry {
  return new SessionRegistry({ ...DEFAULT_LIMITS, ...overrides }, now);
}

function request(overrides: Partial<OpenRequest> = {}): OpenRequest {
  return {
    sessionId: randomUUID(),
    ownerId: "owner-a",
    deviceId: "device-1",
    localPaneId: randomUUID(),
    publisherEpoch: 0,
    ...overrides,
  };
}

/** Open a session that is known to succeed, so the tests can work with the session itself. */
function opened(store: SessionRegistry, overrides: Partial<OpenRequest> = {}) {
  const result = store.open(request(overrides));
  assert.equal(result.ok, true);
  if (!result.ok) throw new Error("unreachable");
  return result.session;
}

describe("opening", () => {
  it("registers a session under its durable id", () => {
    const store = registry();
    const sessionId = randomUUID();
    const session = opened(store, { sessionId });
    assert.equal(session.id, sessionId);
    assert.equal(store.get(sessionId), session);
  });

  it("is idempotent on the session id", () => {
    const store = registry();
    const sessionId = randomUUID();
    const first = opened(store, { sessionId });
    const second = store.open(request({ sessionId }));
    assert.equal(second.ok, true);
    if (!second.ok) return;
    assert.equal(second.created, false, "a second registration must not create a second session");
    assert.equal(second.session, first);
    assert.equal(store.size, 1);
  });

  it("adopts a newer epoch but never goes backwards", () => {
    const store = registry();
    const sessionId = randomUUID();
    const session = opened(store, { sessionId, publisherEpoch: 0 });
    assert.equal(session.epoch, 0);

    store.open(request({ sessionId, publisherEpoch: 4 }));
    assert.equal(session.epoch, 4, "the database is the authority on the epoch");

    // A stale registration must not re-admit a generation the database has already fenced out.
    store.open(request({ sessionId, publisherEpoch: 2 }));
    assert.equal(session.epoch, 4);
  });

  it("refuses past the process publisher budget", () => {
    const store = registry({ maxPublishersPerProcess: 2 });
    assert.equal(store.open(request({ sessionId: randomUUID() })).ok, true);
    assert.equal(store.open(request({ sessionId: randomUUID() })).ok, true);
    const overflow = store.open(request({ sessionId: randomUUID() }));
    assert.equal(overflow.ok, false);
    if (overflow.ok) return;
    assert.equal(overflow.reason, "process_publisher_limit");
  });

  it("frees a slot when a session ends", () => {
    const store = registry({ maxPublishersPerProcess: 1 });
    const sessionId = randomUUID();
    assert.equal(store.open(request({ sessionId })).ok, true);
    assert.equal(store.open(request({ sessionId: randomUUID() })).ok, false);

    store.end(sessionId);
    assert.equal(store.open(request({ sessionId: randomUUID() })).ok, true);
  });
});

describe("viewers", () => {
  it("refuses before adding, so the set never exceeds the cap", () => {
    const store = registry({ maxViewersPerStream: 1 });
    const session = opened(store);
    assert.equal(session.admitViewer("v1").ok, true);
    const refused = session.admitViewer("v2");
    assert.equal(refused.ok, false);
    if (refused.ok) return;
    assert.equal(refused.reason, "viewer_limit");
    assert.equal(session.viewerCount, 1, "the refused viewer was never added");
  });

  it("reports the count as viewers come and go", () => {
    const store = registry();
    const session = opened(store);
    session.admitViewer("v1");
    session.admitViewer("v2");
    assert.equal(session.viewerCount, 2);
    assert.equal(session.removeViewer("v1"), true);
    assert.equal(session.removeViewer("v1"), false, "removing twice is not a second removal");
    assert.equal(session.viewerCount, 1);
  });

  it("refuses a viewer on an ended session", () => {
    const store = registry();
    const session = opened(store);
    session.end();
    const refused = session.admitViewer("v1");
    assert.equal(refused.ok, false);
    if (refused.ok) return;
    assert.equal(refused.reason, "session_ended");
  });
});

describe("the replay ring", () => {
  it("records a frame at the seq the publisher gave it", () => {
    const store = registry();
    const session = opened(store);
    assert.equal(session.publish(1, 10, "one"), true);
    assert.equal(session.publish(2, 10, "two"), true);
    assert.equal(session.lastSeq, 2);
    assert.equal(session.replayBytes, 20);
  });

  it("lets a snapshot's frames share one seq", () => {
    const store = registry();
    const session = opened(store);
    // A snapshot's begin, its chunks and its end all belong to the position the begin established.
    assert.equal(session.publish(0, 10, "hello"), true);
    assert.equal(session.publish(1, 10, "begin"), true);
    assert.equal(session.publish(1, 10, "chunk"), true);
    assert.equal(session.publish(1, 10, "end"), true);
    assert.equal(session.lastSeq, 1);
  });

  it("refuses a seq that went backwards", () => {
    const store = registry();
    const session = opened(store);
    session.publish(5, 10, "five");
    assert.equal(session.publish(4, 10, "four"), false, "replaying it would deliver out of order");
    assert.equal(session.lastSeq, 5);
  });

  it("refuses an oversized frame before storing it", () => {
    const store = registry({ replayBytesPerSession: 100 });
    const session = opened(store);
    assert.equal(session.publish(1, 101, "too big"), false);
    assert.equal(session.replayBytes, 0, "nothing was copied, so there is nothing to evict");
  });

  it("evicts by bytes once the ring is over budget", () => {
    const store = registry({ replayBytesPerSession: 30 });
    const session = opened(store);
    for (let seq = 1; seq <= 4; seq += 1) session.publish(seq, 10, `frame-${seq}`);
    assert.equal(session.replayBytes, 30, "trimmed to the budget rather than held above it");
  });

  it("evicts by age against the injected clock", () => {
    let clock = 1_000;
    const store = registry({ replayWindowMs: 30_000, replayBytesPerSession: 1_000 }, () => clock);
    const session = opened(store);
    session.publish(1, 10, "old");

    clock += 40_000;
    session.publish(2, 10, "new");
    assert.equal(session.replayBytes, 10, "the frame older than the window is gone");
  });
});

describe("replay", () => {
  it("returns nothing when the viewer has seen everything", () => {
    const store = registry();
    const session = opened(store);
    session.publish(1, 10, "one");
    assert.deepEqual(session.replayFrom(1), []);
    assert.deepEqual(session.replayFrom(9), [], "ahead of the stream is still nothing to send");
  });

  it("replays the tail a viewer is missing", () => {
    const store = registry({ replayBytesPerSession: 1_000 });
    const session = opened(store);
    for (let seq = 1; seq <= 3; seq += 1) session.publish(seq, 10, `frame-${seq}`);
    const frames = session.replayFrom(1);
    assert.equal(frames?.length, 2);
    assert.deepEqual(
      frames?.map((frame) => frame.seq),
      [2, 3],
    );
  });

  it("returns the stream start to a viewer that has applied nothing", () => {
    const store = registry({ replayBytesPerSession: 1_000 });
    const session = opened(store);
    session.publish(0, 10, "hello");
    session.publish(1, 10, "one");

    const frames = session.replayFrom(0);
    assert.deepEqual(
      frames?.map((frame) => frame.seq),
      [0, 1],
      "the hello sits at seq 0 and must not be filtered out by a `seq > 0` test",
    );
  });

  it("asks for a resync when the gap has been evicted", () => {
    const store = registry({ replayBytesPerSession: 20 });
    const session = opened(store);
    for (let seq = 1; seq <= 4; seq += 1) session.publish(seq, 10, `frame-${seq}`);
    // The ring now starts at seq 3, so a viewer at 1 is missing 2 and can never be caught up.
    assert.equal(session.replayFrom(1), null);
  });

  it("asks for a resync when the stream start is gone", () => {
    const store = registry({ replayBytesPerSession: 20 });
    const session = opened(store);
    session.publish(0, 10, "hello");
    for (let seq = 1; seq <= 3; seq += 1) session.publish(seq, 10, `frame-${seq}`);

    assert.equal(session.streamStart(), null, "the hello has been evicted");
    // A viewer with nothing applied cannot be handed deltas: there is no snapshot for them to
    // apply to. A resync is the only honest answer.
    assert.equal(session.replayFrom(0), null);
  });
});

describe("slow viewers", () => {
  it("drops a viewer that cannot keep up rather than buffering for it", () => {
    const store = registry({ maxPendingBytesPerSocket: 100 });
    const session = opened(store);
    session.admitViewer("v1");
    assert.equal(session.queueFor("v1", 60), true);
    assert.equal(session.queueFor("v1", 60), false, "the budget is exceeded, so the socket goes");
    assert.equal(session.viewerCount, 0, "and it is removed, not merely refused");
  });

  it("frees budget as a viewer acknowledges", () => {
    const store = registry({ maxPendingBytesPerSocket: 100 });
    const session = opened(store);
    session.admitViewer("v1");
    session.queueFor("v1", 80);
    session.acknowledge("v1", 80);
    assert.equal(session.queueFor("v1", 80), true, "the acknowledged bytes are available again");
  });

  it("never drops the publisher's frames because a viewer is gone", () => {
    const store = registry({ maxPendingBytesPerSocket: 10 });
    const session = opened(store);
    session.admitViewer("v1");
    session.queueFor("v1", 10);
    session.queueFor("v1", 10);
    // The viewer was dropped; the publisher's own bookkeeping is untouched.
    assert.equal(session.publish(1, 10, "one"), true);
    assert.equal(session.lastSeq, 1);
  });
});

describe("the publisher lease", () => {
  it("goes stale when the publisher stops renewing", () => {
    let clock = 1_000;
    const store = registry({ publisherLeaseMs: 30_000 }, () => clock);
    const session = opened(store);
    assert.equal(session.leaseIsStale, false);

    clock += 30_001;
    assert.equal(session.leaseIsStale, true, "the relay must fail closed before the database does");
  });

  it("is renewed by the publisher", () => {
    let clock = 1_000;
    const store = registry({ publisherLeaseMs: 30_000 }, () => clock);
    const session = opened(store);
    clock += 30_001;
    session.renewLease();
    assert.equal(session.leaseIsStale, false);
  });

  it("reports stale sessions to the caller rather than ending them itself", () => {
    let clock = 1_000;
    const store = registry({ publisherLeaseMs: 30_000 }, () => clock);
    opened(store);
    clock += 30_001;
    assert.equal(store.staleLeases().length, 1);
  });
});

describe("ending", () => {
  it("stays ended, and there is no way back", () => {
    const store = registry();
    const session = opened(store);
    session.admitViewer("v1");
    session.publish(1, 10, "one");
    session.end();

    assert.equal(session.ended, true);
    assert.equal(session.viewerCount, 0, "viewers are cleared");
    assert.equal(session.replayBytes, 0, "and so is everything retained");
    assert.equal(session.publish(2, 10, "two"), false, "an ended session carries no more frames");
    // Not `[]`: an ended session cannot be caught up by replay at all, because there is no host left
    // to send a snapshot and nothing retained to replay.
    assert.equal(session.replayFrom(0), null);

    // A renewal cannot resurrect it, which is what stops a stale publisher bringing it back.
    session.renewLease();
    assert.equal(session.ended, true);
    assert.equal(session.leaseIsStale, false, "an ended session has no lease to go stale");
  });

  it("is idempotent", () => {
    const store = registry();
    const session = opened(store);
    session.end();
    const endedAt = session.endedAt;
    session.end();
    assert.equal(session.endedAt, endedAt, "a second end must not move the timestamp");
  });

  it("drops the session from the registry", () => {
    const store = registry();
    const sessionId = randomUUID();
    opened(store, { sessionId });
    assert.equal(store.end(sessionId), true);
    assert.equal(store.end(sessionId), false, "already gone");
    assert.equal(store.get(sessionId), undefined);
  });
});

describe("listing", () => {
  it("returns one account's sessions, newest first", () => {
    let clock = 1_000;
    const store = registry({}, () => clock);
    const older = opened(store, { ownerId: "a", sessionId: randomUUID() });
    clock += 10;
    const newer = opened(store, { ownerId: "a", sessionId: randomUUID() });
    clock += 10;
    opened(store, { ownerId: "b", sessionId: randomUUID() });

    const listed = store.forAccount("a");
    assert.deepEqual(
      listed.map((session) => session.id),
      [newer.id, older.id],
    );
    assert.equal(
      listed.every((session) => session.ownerId === "a"),
      true,
    );
  });
});
