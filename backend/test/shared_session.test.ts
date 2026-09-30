/**
 * Ticket store tests.
 *
 * A fake clock rather than sleeping: expiry is the whole point of the store and a test that waits
 * thirty real seconds for it is a test nobody runs.
 */

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { TICKET_TTL_MS, TicketStore, hashesEqual, type TicketGrant } from "../src/shared_session/tickets.ts";

function clock(start = 1_700_000_000_000): { now: () => number; advance: (ms: number) => void } {
  let value = start;
  return {
    now: () => value,
    advance: (ms) => {
      value += ms;
    },
  };
}

const viewerGrant: TicketGrant = {
  role: "viewer",
  sessionId: "11111111-1111-4111-8111-111111111111",
  accountId: "22222222-2222-4222-8222-222222222222",
  epoch: "1",
};

const publisherGrant: TicketGrant = {
  role: "publisher",
  sessionId: "11111111-1111-4111-8111-111111111111",
  accountId: "22222222-2222-4222-8222-222222222222",
  deviceId: "33333333-3333-4333-8333-333333333333",
  epoch: "1",
};

describe("ticket lifetime", () => {
  it("admits exactly once", () => {
    const store = new TicketStore();
    const { ticket } = store.issue(viewerGrant);

    const first = store.consume(ticket);
    assert.notEqual(first, null);
    assert.equal(first?.role, "viewer");
    assert.equal(first?.sessionId, viewerGrant.sessionId);

    assert.equal(store.consume(ticket), null, "a ticket must not be usable twice");
  });

  it("keeps the store empty after a single use", () => {
    const store = new TicketStore();
    const { ticket } = store.issue(viewerGrant);
    assert.equal(store.size, 1);
    store.consume(ticket);
    assert.equal(store.size, 0, "consuming must remove the entry, not mark it");
  });

  it("expires after its thirty seconds", () => {
    const time = clock();
    const store = new TicketStore({ now: time.now });
    const { ticket, expiresAt } = store.issue(viewerGrant);
    assert.equal(expiresAt - time.now(), TICKET_TTL_MS);

    time.advance(TICKET_TTL_MS - 1);
    assert.notEqual(store.consume(ticket), null, "still valid one millisecond before expiry");

    const second = store.issue(viewerGrant);
    time.advance(TICKET_TTL_MS + 1);
    assert.equal(store.consume(second.ticket), null, "expired");
  });

  it("returns null for a ticket that was never issued", () => {
    const store = new TicketStore();
    assert.equal(store.consume("not-a-real-ticket"), null);
  });

  it("keeps two tickets independent", () => {
    const store = new TicketStore();
    const a = store.issue(viewerGrant);
    const b = store.issue(publisherGrant);

    assert.notEqual(a.ticket, b.ticket);
    assert.equal(store.consume(b.ticket)?.role, "publisher");
    assert.equal(store.consume(a.ticket)?.role, "viewer");
  });
});

describe("roles", () => {
  it("refuses to mint a publisher ticket with no device", () => {
    const store = new TicketStore();
    // A publisher that cannot name its device could never be admitted, so the bug has to surface
    // here rather than as a socket that connects and is dropped.
    // Built without the key rather than set to undefined: `exactOptionalPropertyTypes`
    // distinguishes an absent property from one explicitly present and undefined.
    const { deviceId: _omitted, ...withoutDevice } = publisherGrant;
    assert.throws(
      () => store.issue(withoutDevice),
      /publisher ticket requires a device/,
    );
  });

  it("carries the epoch so a fenced publisher cannot reconnect", () => {
    const store = new TicketStore();
    const { ticket } = store.issue({ ...publisherGrant, epoch: "7" });
    assert.equal(store.consume(ticket)?.epoch, "7");
  });

  it("carries the device for a publisher and leaves it absent for a viewer", () => {
    const store = new TicketStore();
    const viewer = store.consume(store.issue(viewerGrant).ticket);
    const publisher = store.consume(store.issue(publisherGrant).ticket);

    assert.equal(viewer?.deviceId, undefined);
    assert.equal(publisher?.deviceId, publisherGrant.deviceId);
  });
});

describe("bounds", () => {
  it("sweeps what has expired", () => {
    const time = clock();
    const store = new TicketStore({ now: time.now });
    store.issue(viewerGrant);
    store.issue(viewerGrant);
    assert.equal(store.size, 2);

    time.advance(TICKET_TTL_MS + 1);
    assert.equal(store.sweep(), 2);
    assert.equal(store.size, 0);
  });

  it("evicts rather than growing past its capacity", () => {
    const time = clock();
    const store = new TicketStore({ capacity: 4, now: time.now });

    // Each issue advances the clock, so the eviction order is the issue order.
    for (let index = 0; index < 10; index += 1) {
      store.issue(viewerGrant);
      time.advance(1);
    }

    assert.ok(store.size <= 4, `store grew past its cap: ${store.size}`);
  });

  it("keeps the newest ticket when it evicts", () => {
    const time = clock();
    const store = new TicketStore({ capacity: 2, now: time.now });
    store.issue(viewerGrant);
    time.advance(1);
    store.issue(viewerGrant);
    time.advance(1);
    const newest = store.issue(viewerGrant);

    assert.notEqual(store.consume(newest.ticket), null, "the most recent ticket must survive");
  });
});

describe("hash comparison", () => {
  it("compares equal and unequal digests", () => {
    assert.equal(hashesEqual("abc", "abc"), true);
    assert.equal(hashesEqual("abc", "abd"), false);
    assert.equal(hashesEqual("abc", "abcd"), false, "different lengths are not equal");
  });
});
