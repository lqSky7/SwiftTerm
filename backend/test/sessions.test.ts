/**
 * Relay session registry tests.
 *
 * The clock is injected, so the replay window and the publisher lease are exercised by advancing
 * time rather than by sleeping. Every limit is tested at its boundary — one below the cap is
 * admitted, at the cap is refused — because an off-by-one in an admission check is the difference
 * between a limit and a suggestion.
 */

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  DEFAULT_LIMITS,
  RelaySession,
  SessionRegistry,
  type OpenRequest,
  type SessionLimits,
} from "../src/shared_session/sessions.ts";

function clock(start = 1_700_000_000_000): { now: () => number; advance: (ms: number) => void } {
  let value = start;
  return {
    now: () => value,
    advance: (ms) => {
      value += ms;
    },
  };
}

function request(overrides: Partial<OpenRequest> = {}): OpenRequest {
  return {
    ownerId: "owner-a",
    deviceId: "device-a",
    localPaneId: "pane-a",
    clientRequestId: crypto.randomUUID(),
    requestDigest: "digest-1",
    ...overrides,
  };
}

function registry(overrides: Partial<SessionLimits> = {}) {
  const time = clock();
  return {
    time,
    store: new SessionRegistry({ ...DEFAULT_LIMITS, ...overrides }, time.now),
  };
}

describe("opening a stream", () => {
  it("creates a session at epoch 1", () => {
    const { store } = registry();
    const result = store.open(request());
    assert.equal(result.ok, true);
    if (!result.ok) return;
    assert.equal(result.created, true);
    assert.equal(result.session.epoch, 1);
    assert.equal(result.session.ended, false);
    assert.equal(result.session.viewerCount, 0);
  });

  it("returns the same session for an identical retry", () => {
    const { store } = registry();
    const open = request();
    const first = store.open(open);
    const second = store.open(open);

    assert.equal(first.ok, true);
    assert.equal(second.ok, true);
    if (!first.ok || !second.ok) return;
    assert.equal(second.created, false, "an identical retry must not open a second stream");
    assert.equal(second.session.id, first.session.id);
    assert.equal(store.size, 1);
  });

  it("refuses a reused request id with a changed payload", () => {
    const { store } = registry();
    const open = request();
    store.open(open);
    const changed = store.open({ ...open, requestDigest: "digest-2" });

    assert.equal(changed.ok, false);
    if (changed.ok) return;
    assert.equal(changed.reason, "request_conflict");
  });

  it("refuses a second stream for the same pane", () => {
    const { store } = registry();
    store.open(request({ deviceId: "d1", localPaneId: "p1" }));
    const again = store.open(request({ deviceId: "d1", localPaneId: "p1" }));

    assert.equal(again.ok, false);
    if (again.ok) return;
    assert.equal(again.reason, "pane_already_shared");
  });

  it("allows the same pane id on a different device", () => {
    const { store } = registry();
    store.open(request({ deviceId: "d1", localPaneId: "p1" }));
    const other = store.open(request({ deviceId: "d2", localPaneId: "p1" }));
    assert.equal(other.ok, true);
  });

  it("refuses the sixth stream for one account, and admits the fifth", () => {
    const { store } = registry();
    for (let index = 0; index < DEFAULT_LIMITS.maxStreamsPerAccount; index += 1) {
      const result = store.open(request({ localPaneId: `pane-${index}` }));
      assert.equal(result.ok, true, `stream ${index + 1} should be admitted`);
    }
    const overflow = store.open(request({ localPaneId: "pane-overflow" }));
    assert.equal(overflow.ok, false);
    if (overflow.ok) return;
    assert.equal(overflow.reason, "account_stream_limit");
  });

  it("counts accounts separately", () => {
    const { store } = registry({ maxStreamsPerAccount: 1 });
    // Distinct panes on purpose: one stream per pane is a separate rule, and a shared pane would
    // trip it before the account cap was ever consulted.
    assert.equal(store.open(request({ ownerId: "a", localPaneId: "pane-a" })).ok, true);
    assert.equal(
      store.open(request({ ownerId: "b", localPaneId: "pane-b" })).ok,
      true,
      "another account has its own cap",
    );
    assert.equal(store.open(request({ ownerId: "a", localPaneId: "pane-a2" })).ok, false);
  });

  it("refuses past the per-process publisher cap", () => {
    const { store } = registry({ maxPublishersPerProcess: 3 });
    for (let index = 0; index < 3; index += 1) {
      // One pane each: sharing a pane would hit the per-pane rule first and the process cap would
      // never be exercised.
      assert.equal(store.open(request({ ownerId: `o${index}`, localPaneId: `pane-${index}` })).ok, true);
    }
    const overflow = store.open(request({ ownerId: "o9", localPaneId: "pane-9" }));
    assert.equal(overflow.ok, false);
    if (overflow.ok) return;
    assert.equal(overflow.reason, "process_publisher_limit");
  });
});

describe("ending a stream", () => {
  it("frees the account's stream budget", () => {
    const { store } = registry({ maxStreamsPerAccount: 1 });
    const first = store.open(request());
    assert.equal(first.ok, true);
    if (!first.ok) return;

    assert.equal(store.end(first.session.id), true);
    assert.equal(store.size, 0);
    assert.equal(store.open(request()).ok, true, "the freed slot is usable again");
  });

  it("stays ended: no viewers, no frames", () => {
    const { store } = registry();
    const opened = store.open(request());
    assert.equal(opened.ok, true);
    if (!opened.ok) return;
    const session = opened.session;
    session.end();

    assert.equal(session.ended, true);
    assert.notEqual(session.endedAt, null);
    assert.deepEqual(session.admitViewer("v1"), { ok: false, reason: "session_ended" });
    assert.equal(session.publish(10), null, "an ended session emits nothing");
    assert.equal(session.end(), undefined, "ending twice is safe");
  });
});

describe("viewers", () => {
  it("admits up to the cap and refuses past it", () => {
    const { store } = registry({ maxViewersPerStream: 2 });
    const opened = store.open(request());
    assert.equal(opened.ok, true);
    if (!opened.ok) return;
    const session = opened.session;

    assert.equal(session.admitViewer("v1").ok, true);
    assert.equal(session.admitViewer("v2").ok, true);
    const third = session.admitViewer("v3");
    assert.equal(third.ok, false);
    if (third.ok) return;
    assert.equal(third.reason, "viewer_limit");
    assert.equal(session.viewerCount, 2, "a refused viewer is never added");
  });

  it("reports the count falling when a viewer leaves, which is what pauses encoding", () => {
    const { store } = registry();
    const opened = store.open(request());
    assert.equal(opened.ok, true);
    if (!opened.ok) return;
    const session = opened.session;

    session.admitViewer("v1");
    session.admitViewer("v2");
    assert.equal(session.viewerCount, 2);
    session.removeViewer("v1");
    session.removeViewer("v2");
    assert.equal(session.viewerCount, 0, "zero viewers is the signal to stop encoding");
  });

  it("drops a slow viewer rather than buffering for it without limit", () => {
    const { store } = registry({ maxPendingBytesPerSocket: 100 });
    const opened = store.open(request());
    assert.equal(opened.ok, true);
    if (!opened.ok) return;
    const session = opened.session;
    session.admitViewer("slow");

    assert.equal(session.queueFor("slow", 60), true);
    assert.equal(session.queueFor("slow", 30), true);
    // The next frame would exceed the socket's budget, so the viewer is dropped instead of being
    // allowed to grow — a slow viewer must never stall the host.
    assert.equal(session.queueFor("slow", 30), false);
    assert.equal(session.viewerCount, 0);
  });

  it("frees a viewer's budget when it acknowledges", () => {
    const { store } = registry({ maxPendingBytesPerSocket: 100 });
    const opened = store.open(request());
    assert.equal(opened.ok, true);
    if (!opened.ok) return;
    const session = opened.session;
    session.admitViewer("v1");

    session.queueFor("v1", 90);
    session.acknowledge("v1", 90);
    assert.equal(session.queueFor("v1", 90), true, "acknowledged bytes are no longer pending");
  });
});

describe("frames and replay", () => {
  it("numbers frames from 1 and reports the last seq", () => {
    const { store } = registry();
    const opened = store.open(request());
    assert.equal(opened.ok, true);
    if (!opened.ok) return;
    const session = opened.session;

    assert.equal(session.lastSeq, 0);
    assert.equal(session.publish(10)?.seq, 1);
    assert.equal(session.publish(10)?.seq, 2);
    assert.equal(session.lastSeq, 2);
  });

  it("replays only what a viewer has not seen", () => {
    const { store } = registry();
    const opened = store.open(request());
    assert.equal(opened.ok, true);
    if (!opened.ok) return;
    const session = opened.session;
    for (let index = 0; index < 5; index += 1) session.publish(10);

    const missed = session.replayFrom(2);
    assert.notEqual(missed, null);
    assert.deepEqual(missed?.map((frame) => frame.seq), [3, 4, 5]);
    assert.deepEqual(session.replayFrom(5), [], "a viewer that is current has nothing to replay");
  });

  it("asks for a snapshot when the gap has already been evicted", () => {
    const { store } = registry({ replayBytesPerSession: 30 });
    const opened = store.open(request());
    assert.equal(opened.ok, true);
    if (!opened.ok) return;
    const session = opened.session;
    for (let index = 0; index < 6; index += 1) session.publish(10);

    // seq 1 is long gone, so a viewer at 0 cannot be caught up by replay and must resync.
    assert.equal(session.replayFrom(0), null);
  });

  it("refuses a frame larger than the whole ring", () => {
    const { store } = registry({ replayBytesPerSession: 100 });
    const opened = store.open(request());
    assert.equal(opened.ok, true);
    if (!opened.ok) return;
    const session = opened.session;

    assert.equal(session.publish(101), null, "refused before anything is stored");
    assert.equal(session.lastSeq, 0);
    assert.equal(session.replayBytes, 0);
  });

  it("evicts by age", () => {
    const time = clock();
    const store = new SessionRegistry({ ...DEFAULT_LIMITS, replayWindowMs: 1_000 }, time.now);
    const opened = store.open(request());
    assert.equal(opened.ok, true);
    if (!opened.ok) return;
    const session = opened.session;
    session.publish(10);
    session.publish(10);

    time.advance(1_001);
    session.publish(10);
    // The two older frames are outside the window, so the ring holds only the newest.
    assert.equal(session.replayBytes, 10);
    assert.equal(session.replayFrom(0), null, "the older frames are gone");
  });

  it("bounds retained bytes across every session", () => {
    const { store } = registry();
    const a = store.open(request({ ownerId: "a", deviceId: "d-a", localPaneId: "p1" }));
    const b = store.open(request({ ownerId: "b", deviceId: "d-b", localPaneId: "p1" }));
    assert.equal(a.ok, true);
    assert.equal(b.ok, true);
    if (!a.ok || !b.ok) return;

    a.session.publish(1_000);
    b.session.publish(2_000);
    assert.equal(store.retainedBytes, 3_000);
  });
});

describe("publisher leases", () => {
  it("goes stale once the publisher stops renewing", () => {
    const time = clock();
    const store = new SessionRegistry({ ...DEFAULT_LIMITS, publisherLeaseMs: 30_000 }, time.now);
    const opened = store.open(request());
    assert.equal(opened.ok, true);
    if (!opened.ok) return;

    assert.equal(opened.session.leaseIsStale, false);
    time.advance(29_999);
    assert.equal(opened.session.leaseIsStale, false, "still inside the lease");
    time.advance(2);
    assert.equal(opened.session.leaseIsStale, true);
    assert.deepEqual(store.staleLeases().map((s) => s.id), [opened.session.id]);
  });

  it("clears staleness on renewal", () => {
    const time = clock();
    const store = new SessionRegistry({ ...DEFAULT_LIMITS, publisherLeaseMs: 30_000 }, time.now);
    const opened = store.open(request());
    assert.equal(opened.ok, true);
    if (!opened.ok) return;

    time.advance(31_000);
    assert.equal(opened.session.leaseIsStale, true);
    opened.session.renewLease();
    assert.equal(opened.session.leaseIsStale, false);
  });

  it("never renews an ended session back to life", () => {
    const time = clock();
    const store = new SessionRegistry({ ...DEFAULT_LIMITS, publisherLeaseMs: 30_000 }, time.now);
    const opened = store.open(request());
    assert.equal(opened.ok, true);
    if (!opened.ok) return;
    opened.session.end();

    time.advance(31_000);
    opened.session.renewLease();
    assert.equal(opened.session.ended, true);
  });
});

describe("owner's session list", () => {
  it("lists only that account's sessions, newest first", () => {
    const time = clock();
    const store = new SessionRegistry(DEFAULT_LIMITS, time.now);
    const older = store.open(request({ ownerId: "a", localPaneId: "p1" }));
    time.advance(10);
    const newer = store.open(request({ ownerId: "a", localPaneId: "p2" }));
    store.open(request({ ownerId: "b", localPaneId: "p1" }));
    assert.equal(older.ok, true);
    assert.equal(newer.ok, true);
    if (!older.ok || !newer.ok) return;

    const listed = store.forAccount("a").map((session) => session.id);
    assert.deepEqual(listed, [newer.session.id, older.session.id]);
  });
});

describe("session identity", () => {
  it("is constructible directly, for a caller that needs a session without the registry", () => {
    const time = clock();
    const session = new RelaySession(
      { ...request(), title: "build" },
      DEFAULT_LIMITS,
      time.now,
    );
    assert.equal(session.title, "build");
    assert.equal(session.epoch, 1);
  });
});
