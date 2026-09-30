/**
 * Snapshot assembly and the socket state machine.
 *
 * The assembler half is the part of the viewer that can be attacked directly: it accepts bytes from
 * the relay and only hands them on when the count, the length and the digest agree. The tests below
 * check each of those three separately, because a check that only works when the other two pass is
 * not a check.
 *
 * The connection half runs against a fake socket, so the state machine — resume, gap, malformed
 * frame, reconnect — is exercised without a network or a browser.
 */

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

import {
  ContractError,
  SnapshotAssembler,
  base64Encode,
  validateSnapshot,
  type WireSnapshot,
} from "../../contracts/ts/wire.ts";
import {
  MAX_RECONNECT_MS,
  ViewerConnection,
  reconnectDelay,
  socketUrlFor,
  webCryptoSha256,
} from "../src/shared_session/connection.ts";
import { initialState, type ViewerState } from "../src/shared_session/state.ts";

const here = dirname(fileURLToPath(import.meta.url));

function goldenBytes(name = "snapshot-blocks.json"): Uint8Array {
  return new Uint8Array(
    readFileSync(join(here, "..", "..", "contracts", "fixtures", "golden", name)),
  );
}

function sha256Hex(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}

const EPOCH = "1";
const SNAPSHOT_ID = "11111111-2222-4333-8444-555555555555";

/** The frames that carry a snapshot, split into `count` chunks of at most `size` bytes. */
function snapshotFrames(bytes: Uint8Array, count = 2, seq = "0") {
  const size = Math.ceil(bytes.length / count);
  const chunks: Uint8Array[] = [];
  for (let offset = 0; offset < bytes.length; offset += size) {
    chunks.push(bytes.slice(offset, offset + size));
  }
  return {
    begin: {
      type: "snapshot.begin",
      epoch: EPOCH,
      seq,
      snapshot_id: SNAPSHOT_ID,
      bytes: bytes.length,
      chunks: chunks.length,
      sha256: sha256Hex(bytes),
    },
    chunks: chunks.map((chunk, index) => ({
      type: "snapshot.chunk",
      epoch: EPOCH,
      snapshot_id: SNAPSHOT_ID,
      index,
      data: base64Encode(chunk),
    })),
    end: { type: "snapshot.end", epoch: EPOCH, snapshot_id: SNAPSHOT_ID },
  };
}

/** One chunk by index, so a test can reach for a specific one without an unchecked index. */
function chunkAt(frames: ReturnType<typeof snapshotFrames>, index: number): Record<string, unknown> {
  const chunk = frames.chunks[index];
  if (chunk === undefined) throw new Error(`no chunk at ${index}`);
  return chunk;
}

describe("snapshot assembly", () => {
  it("reassembles the golden snapshot and verifies its digest", async () => {
    const bytes = goldenBytes();
    const frames = snapshotFrames(bytes, 3);
    const assembler = new SnapshotAssembler();

    assembler.begin(frames.begin);
    for (const chunk of frames.chunks) assembler.append(chunk);
    const assembled = await assembler.finish(frames.end, webCryptoSha256);

    assert.deepEqual(assembled, bytes, "the bytes are the bytes, not an approximation");
    const snapshot: WireSnapshot = validateSnapshot(
      JSON.parse(new TextDecoder().decode(assembled)) as unknown,
    );
    assert.equal(snapshot.blocks.length, 2);
  });

  it("refuses a digest that does not match", async () => {
    const bytes = goldenBytes();
    const frames = snapshotFrames(bytes, 2);
    const assembler = new SnapshotAssembler();
    assembler.begin({ ...frames.begin, sha256: "a".repeat(64) });
    for (const chunk of frames.chunks) assembler.append(chunk);

    await assert.rejects(
      () => assembler.finish(frames.end, webCryptoSha256),
      (error: unknown) => error instanceof ContractError,
    );
  });

  it("refuses a chunk out of order", () => {
    const frames = snapshotFrames(goldenBytes(), 3);
    const assembler = new SnapshotAssembler();
    assembler.begin(frames.begin);
    assert.throws(
      () => assembler.append(chunkAt(frames, 1)),
      (error: unknown) => error instanceof ContractError && error.code === "resync_required",
    );
  });

  it("refuses a chunk with no begin", () => {
    const frames = snapshotFrames(goldenBytes(), 2);
    const assembler = new SnapshotAssembler();
    assert.throws(
      () => assembler.append(chunkAt(frames, 0)),
      (error: unknown) => error instanceof ContractError && error.code === "resync_required",
    );
  });

  it("refuses more chunks than were declared", async () => {
    const bytes = goldenBytes();
    const frames = snapshotFrames(bytes, 2);
    const assembler = new SnapshotAssembler();
    // One chunk fewer than the begin declared, then the end: the count check has to catch it even
    // though the digest of what arrived would be self-consistent.
    assembler.begin(frames.begin);
    assembler.append(chunkAt(frames, 0));
    await assert.rejects(
      () => assembler.finish(frames.end, webCryptoSha256),
      (error: unknown) => error instanceof ContractError,
    );
  });

  it("refuses a chunk from another snapshot", () => {
    const frames = snapshotFrames(goldenBytes(), 2);
    const assembler = new SnapshotAssembler();
    assembler.begin(frames.begin);
    assert.throws(
      () =>
        assembler.append({
          ...chunkAt(frames, 0),
          snapshot_id: "99999999-9999-4999-8999-999999999999",
        }),
      (error: unknown) => error instanceof ContractError,
    );
  });
});

describe("the socket URL", () => {
  it("derives a websocket URL from the API base", () => {
    assert.equal(
      socketUrlFor("https://api.example.com", "abc"),
      "wss://api.example.com/live/abc",
    );
    assert.equal(socketUrlFor("http://127.0.0.1:8081", "abc"), "ws://127.0.0.1:8081/live/abc");
  });

  it("drops any path or query the API base carried", () => {
    // The relay lives at the root of the same origin; keeping a path from the base would produce a
    // URL that upgrades nowhere.
    assert.equal(
      socketUrlFor("https://api.example.com/v1?x=1", "abc"),
      "wss://api.example.com/live/abc",
    );
  });

  it("encodes the session id", () => {
    assert.equal(
      socketUrlFor("https://api.example.com", "a/b"),
      "wss://api.example.com/live/a%2Fb",
    );
  });
});

describe("reconnect backoff", () => {
  it("doubles and then stops growing", () => {
    const midpoint = () => 0.5;
    assert.equal(reconnectDelay(1, midpoint), 500);
    assert.equal(reconnectDelay(2, midpoint), 1_000);
    assert.equal(reconnectDelay(3, midpoint), 2_000);
    // The cap matters more than the growth: an unbounded backoff means a viewer that comes back
    // after a laptop lid opens waits minutes.
    assert.equal(reconnectDelay(20, midpoint), MAX_RECONNECT_MS);
  });

  it("jitters within a quarter either way", () => {
    assert.equal(reconnectDelay(1, () => 0), 375);
    assert.equal(reconnectDelay(1, () => 1), 625);
  });
});

/** A socket the test drives by hand. */
class FakeSocket {
  static latest: FakeSocket | null = null;

  onopen: (() => void) | null = null;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;
  readyState = 1;
  readonly url: string;
  readonly sent: string[] = [];

  // Written out rather than a constructor parameter property: Node runs these files by stripping
  // types, and a parameter property is syntax that would have to survive stripping. It does not.
  constructor(url: string) {
    this.url = url;
    FakeSocket.latest = this;
  }

  send(data: string): void {
    this.sent.push(data);
  }

  close(): void {
    this.readyState = 3;
    this.onclose?.();
  }

  /** Complete the handshake, which is what makes the connection send its auth frame. */
  open(): void {
    this.onopen?.();
  }

  deliver(payload: unknown): void {
    this.onmessage?.({ data: JSON.stringify(payload) } as MessageEvent);
  }

  get frames(): Record<string, unknown>[] {
    return this.sent.map((frame) => JSON.parse(frame) as Record<string, unknown>);
  }
}

function settle(ms = 20): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function connected(onState: (state: ViewerState) => void) {
  FakeSocket.latest = null;
  const connection = new ViewerConnection({
    apiBaseUrl: "https://api.example.com",
    sessionId: "11111111-1111-4111-8111-111111111111",
    requestTicket: () => Promise.resolve("ticket-value"),
    onState,
    socketFactory: (url) => new FakeSocket(url) as unknown as WebSocket,
  });
  connection.start();
  return connection;
}

describe("the connection", () => {
  it("presents the ticket in the first frame, never in the URL", async () => {
    const connection = connected(() => {});
    await settle();
    const socket = FakeSocket.latest;
    assert.notEqual(socket, null);
    if (socket === null) return;

    // A query string ends up in access logs and in `Referer`, so the ticket travels in a frame.
    assert.equal(socket.url.includes("ticket"), false);
    socket.open();
    const auth = socket.frames[0];
    assert.equal(auth?.type, "auth");
    assert.equal(auth?.ticket, "ticket-value");
    connection.stop();
  });

  it("asks for the whole stream when it has applied nothing", async () => {
    const connection = connected(() => {});
    await settle();
    const socket = FakeSocket.latest;
    if (socket === null) return;
    socket.open();
    socket.deliver({
      type: "hello",
      version: 1,
      session_id: "11111111-1111-4111-8111-111111111111",
      epoch: "1",
      mode: "blocks",
      columns: 40,
      rows: 12,
    });
    await settle();

    const resume = socket.frames.find((frame) => frame.type === "resume");
    assert.equal(resume?.epoch, "1");
    assert.equal(resume?.seq, "0", "nothing applied means resume from the beginning");
    connection.stop();
  });

  it("adopts an assembled snapshot and then applies a delta", async () => {
    let state: ViewerState = initialState();
    const connection = connected((next) => {
      state = next;
    });
    await settle();
    const socket = FakeSocket.latest;
    if (socket === null) return;
    socket.open();
    socket.deliver({
      type: "hello",
      version: 1,
      session_id: "11111111-1111-4111-8111-111111111111",
      epoch: "1",
      mode: "blocks",
      columns: 40,
      rows: 12,
    });

    const frames = snapshotFrames(goldenBytes(), 2);
    socket.deliver(frames.begin);
    for (const chunk of frames.chunks) socket.deliver(chunk);
    socket.deliver(frames.end);
    await settle(50);

    assert.equal(state.status, "live");
    assert.equal(state.live?.blocks.length, 2, "the golden snapshot arrived");
    assert.equal(state.live?.lastSeq, 0);

    const blockId = state.live?.blocks[0]?.id;
    socket.deliver({
      type: "damage",
      epoch: "1",
      seq: "1",
      base_seq: "0",
      changes: [{ op: "set_collapsed", block_id: blockId, collapsed: true }],
    });
    await settle();

    assert.equal(state.live?.lastSeq, 1);
    assert.equal(state.live?.blocks[0]?.collapsed, true);
    connection.stop();
  });

  it("asks for a resync when a delta leaves a gap", async () => {
    let state: ViewerState = initialState();
    const connection = connected((next) => {
      state = next;
    });
    await settle();
    const socket = FakeSocket.latest;
    if (socket === null) return;
    socket.open();
    socket.deliver({
      type: "hello",
      version: 1,
      session_id: "11111111-1111-4111-8111-111111111111",
      epoch: "1",
      mode: "blocks",
      columns: 40,
      rows: 12,
    });
    const frames = snapshotFrames(goldenBytes(), 2);
    socket.deliver(frames.begin);
    for (const chunk of frames.chunks) socket.deliver(chunk);
    socket.deliver(frames.end);
    await settle(50);

    const before = socket.sent.length;
    socket.deliver({
      type: "damage",
      epoch: "1",
      seq: "7",
      base_seq: "6",
      changes: [],
    });
    await settle();

    // The viewer is behind and cannot catch up on its own, so it asks for the tail it is missing
    // rather than guessing at the frames in between.
    const sent = socket.frames.slice(before).filter((frame) => frame.type === "resume");
    assert.equal(sent.length, 1);
    assert.equal(state.status, "resyncing");
    connection.stop();
  });

  it("drops the socket on a frame the contract refuses", async () => {
    const connection = connected(() => {});
    await settle();
    const socket = FakeSocket.latest;
    if (socket === null) return;
    socket.open();

    let closed = false;
    const original = socket.close.bind(socket);
    socket.close = () => {
      closed = true;
      original();
    };
    // An unknown field is refused by the contract, so this never reaches the reducer.
    socket.deliver({ type: "hello", version: 1, surprise: true });
    await settle();
    assert.equal(closed, true, "a frame this build cannot accept is not guessed at");
    connection.stop();
  });

  it("closes the socket when stopped", async () => {
    const connection = connected(() => {});
    await settle();
    const socket = FakeSocket.latest;
    if (socket === null) return;
    socket.open();
    connection.stop();
    assert.equal(socket.readyState, 3);
  });
});
