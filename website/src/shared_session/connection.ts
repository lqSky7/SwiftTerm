/**
 * The viewer's socket.
 *
 * It does four things, and each one is somewhere a live viewer usually goes wrong:
 *
 *   * **It validates every inbound frame against the contract**, with the `relay_to_viewer`
 *     direction. The relay is not trusted to have validated anything: it forwards bytes, and a
 *     frame this build does not understand must be refused here rather than rendered.
 *   * **It assembles snapshots through the contract's `SnapshotAssembler`** with a Web Crypto digest.
 *     Browser SHA-256 is asynchronous, which is why the assembler takes the digest as a callback
 *     rather than computing it — and why a snapshot is never adopted before its bytes are verified.
 *   * **It resumes rather than restarts.** After a reconnect it asks for the tail it is missing; if
 *     the relay cannot supply it, the relay says `resync` and the host sends a fresh snapshot.
 *   * **It backs off.** A relay restart must not become a reconnect storm: the delay doubles with
 *     jitter and is capped at thirty seconds.
 *
 * No DOM and no React: it takes a socket factory and a ticket fetcher, so the whole state machine
 * is exercisable without a browser.
 */

import {
  ContractError,
  SnapshotAssembler,
  validateFrame,
  validateSnapshot,
  type WireDamage,
  type WireFrame,
  type WireSnapshot,
} from "../../../contracts/ts/wire.ts";
import { applyDamage, applySnapshot, initialState, withRefusal, withStatus, type ViewerState } from "./state.ts";

/** The subprotocol the relay selects. A browser that is not granted one fails the handshake. */
export const SUBPROTOCOL = "swiftterm.live.v1";

/** The backoff cap. Past this, waiting longer buys nothing and makes a restart feel broken. */
export const MAX_RECONNECT_MS = 30_000;
const BASE_RECONNECT_MS = 500;

export interface ViewerConnectionOptions {
  /** The API base, `http(s)://…`. The socket URL is derived from it. */
  readonly apiBaseUrl: string;
  readonly sessionId: string;
  /** Mints a one-use viewer ticket. Injected so the state machine needs no fetch. */
  readonly requestTicket: () => Promise<string>;
  readonly onState: (state: ViewerState) => void;
  /** A short status line. Never terminal content — this is shown in the chrome. */
  readonly onNotice?: (notice: string) => void;
  /** Injected for tests. */
  readonly socketFactory?: (url: string) => WebSocket;
  /** Injected for tests; defaults to Web Crypto. */
  readonly digest?: (bytes: Uint8Array) => Promise<string>;
}

export function socketUrlFor(apiBaseUrl: string, sessionId: string): string {
  const url = new URL(apiBaseUrl);
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  // The API base may carry a path; the relay lives at the root of the same origin.
  url.pathname = `/live/${encodeURIComponent(sessionId)}`;
  url.search = "";
  return url.toString();
}

/** Lowercase hex SHA-256. The assembler compares it against the digest the host declared. */
export async function webCryptoSha256(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes as unknown as ArrayBuffer);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

/**
 * The reconnect delay for a given attempt, before jitter.
 *
 * Exported and pure so the growth and the cap are testable without waiting for them. The jitter is
 * not decoration: without it, every browser that lost the same relay reconnects in the same
 * millisecond and the relay is hit by the whole population at once.
 */
export function reconnectDelay(attempt: number, random: () => number = Math.random): number {
  const ceiling = Math.min(MAX_RECONNECT_MS, BASE_RECONNECT_MS * 2 ** (attempt - 1));
  return Math.round(ceiling * (0.75 + random() * 0.5));
}

export class ViewerConnection {
  readonly #options: ViewerConnectionOptions;
  readonly #assembler = new SnapshotAssembler();
  readonly #socketFactory: (url: string) => WebSocket;
  readonly #digest: (bytes: Uint8Array) => Promise<string>;

  #state: ViewerState = initialState();
  #socket: WebSocket | null = null;
  #retryTimer: ReturnType<typeof setTimeout> | null = null;
  #attempt = 0;
  #stopped = false;
  /** The geometry from the last `hello`, so a damage frame can be validated before a snapshot. */
  #helloColumns: number | undefined = undefined;

  constructor(options: ViewerConnectionOptions) {
    this.#options = options;
    this.#socketFactory =
      options.socketFactory ?? ((url: string) => new WebSocket(url, SUBPROTOCOL));
    this.#digest = options.digest ?? webCryptoSha256;
  }

  get state(): ViewerState {
    return this.#state;
  }

  start(): void {
    this.#stopped = false;
    void this.#connect();
  }

  stop(): void {
    this.#stopped = true;
    if (this.#retryTimer !== null) clearTimeout(this.#retryTimer);
    this.#retryTimer = null;
    this.#socket?.close();
    this.#socket = null;
  }

  async #connect(): Promise<void> {
    if (this.#stopped) return;
    this.#set(withStatus(this.#state, "connecting"));

    let ticket: string;
    try {
      ticket = await this.#options.requestTicket();
    } catch (error) {
      // A ticket that cannot be minted is a session or network problem, not a protocol one, so it
      // is retried on the same backoff as a dropped socket.
      this.#notice(error instanceof ContractError ? error.code : "could not get a ticket");
      this.#set(withStatus(this.#state, "failed"));
      this.#scheduleReconnect();
      return;
    }
    if (this.#stopped) return;

    let socket: WebSocket;
    try {
      socket = this.#socketFactory(socketUrlFor(this.#options.apiBaseUrl, this.#options.sessionId));
    } catch {
      this.#scheduleReconnect();
      return;
    }
    this.#socket = socket;

    socket.onopen = () => {
      // The ticket is spent here and nowhere else. It is never put in the URL, because a query
      // string ends up in access logs and in `Referer`.
      socket.send(
        JSON.stringify({ type: "auth", ticket, client_id: crypto.randomUUID() }),
      );
    };

    socket.onmessage = (event: MessageEvent) => {
      void this.#handle(String(event.data));
    };

    socket.onclose = () => {
      this.#socket = null;
      if (this.#stopped) return;
      this.#assembler.reset();
      this.#notice("disconnected, reconnecting");
      this.#scheduleReconnect();
    };

    socket.onerror = () => {
      // `onclose` follows, so nothing is done here but making sure the error is not swallowed by
      // the browser's console as an unhandled event.
    };
  }

  async #handle(text: string): Promise<void> {
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      this.#notice("the relay sent something that is not JSON");
      this.#socket?.close();
      return;
    }

    let frame: WireFrame;
    try {
      frame = validateFrame(
        parsed,
        "relay_to_viewer",
        this.#state.live?.columns ?? this.#helloColumns,
      );
    } catch (error) {
      // A frame this build cannot accept is not something to guess at. Closing makes the relay mint
      // a fresh ticket and the host send a snapshot, which is the only state that is known good.
      this.#notice(error instanceof ContractError ? `refused a frame: ${error.code}` : "refused a frame");
      this.#socket?.close();
      return;
    }

    switch (frame.type) {
      case "hello": {
        const value = frame.value as { columns: number; epoch: string };
        this.#helloColumns = value.columns;
        this.#attempt = 0;
        if (this.#state.live === null) this.#set(withStatus(this.#state, "waiting"));
        this.#resume(value.epoch);
        return;
      }

      case "snapshot.begin": {
        try {
          this.#assembler.begin(frame.value as Record<string, unknown>);
        } catch {
          this.#notice("a snapshot started while one was in flight");
          this.#resync();
        }
        return;
      }

      case "snapshot.chunk": {
        try {
          this.#assembler.append(frame.value as Record<string, unknown>);
        } catch {
          this.#notice("a snapshot chunk could not be placed");
          this.#resync();
        }
        return;
      }

      case "snapshot.end": {
        await this.#finishSnapshot(frame.value as Record<string, unknown>);
        return;
      }

      case "damage": {
        const outcome = applyDamage(this.#state, frame.value as WireDamage);
        if (outcome.applied) {
          this.#set({ ...this.#state, live: outcome.live, status: "live", lastRefusal: null });
          return;
        }
        // A duplicate is expected — the relay replays — and is not worth reacting to. Anything else
        // means this viewer is behind or ahead of the host, and only a snapshot fixes that.
        if (outcome.reason === "duplicate") return;
        this.#set(withRefusal(this.#state, outcome.reason));
        this.#resync();
        return;
      }

      case "resync": {
        // The relay could not supply the gap and is asking the host for a snapshot. Discard any
        // half-assembled transfer so a stale chunk cannot join the new one.
        this.#assembler.reset();
        this.#set(withStatus(this.#state, "resyncing"));
        return;
      }

      case "error": {
        // The host was refused, not this viewer. Worth showing, not worth tearing the socket down.
        const value = frame.value as { code?: string };
        this.#notice(`the relay refused a frame: ${value.code ?? "unknown"}`);
        return;
      }

      default: {
        // `control.granted`, `control.denied`, `control.revoked` and `input.ack` are B3A's. A viewer
        // without control rights still renders, so these are noted and ignored rather than fatal.
        this.#notice(`${frame.type} is not handled by this build`);
        return;
      }
    }
  }

  async #finishSnapshot(value: Record<string, unknown>): Promise<void> {
    let bytes: Uint8Array;
    try {
      bytes = await this.#assembler.finish(value, this.#digest);
    } catch (error) {
      this.#notice(error instanceof ContractError ? `snapshot refused: ${error.code}` : "snapshot refused");
      this.#resync();
      return;
    }

    let snapshot: WireSnapshot;
    try {
      snapshot = validateSnapshot(JSON.parse(new TextDecoder().decode(bytes)) as unknown);
    } catch {
      // The digest matched but the contents are not a snapshot this build accepts. Refusing is the
      // only safe answer: the bytes are authenticated, not understood.
      this.#notice("the snapshot was not valid");
      this.#resync();
      return;
    }

    // The atomic swap. Everything before this point was scratch memory.
    this.#set(applySnapshot(this.#state, snapshot));
    this.#attempt = 0;
  }

  /**
   * Ask for the tail this viewer is missing.
   *
   * `epoch` must match the relay's current epoch or the request is meaningless, so the epoch from
   * the `hello` is used when there is no applied state, and the applied epoch when there is.
   */
  #resume(helloEpoch: string): void {
    const live = this.#state.live;
    const sameEpoch = live !== null && live.epoch === helloEpoch;
    this.#send({
      type: "resume",
      epoch: helloEpoch,
      // Nothing applied, or a different epoch: the only usable answer is the whole stream, which
      // the relay satisfies from its ring or by telling the host to send a snapshot.
      seq: sameEpoch && live !== null ? String(live.lastSeq) : "0",
    });
    if (!sameEpoch) this.#set(withStatus(this.#state, "resyncing"));
  }

  #resync(): void {
    this.#assembler.reset();
    this.#set(withStatus(this.#state, "resyncing"));
    const live = this.#state.live;
    if (live === null) return;
    this.#send({ type: "resume", epoch: live.epoch, seq: String(live.lastSeq) });
  }

  #send(payload: Record<string, unknown>): void {
    const socket = this.#socket;
    if (socket === null || socket.readyState !== 1) return;
    socket.send(JSON.stringify(payload));
  }

  #set(state: ViewerState): void {
    this.#state = state;
    this.#options.onState(state);
  }

  #notice(message: string): void {
    this.#options.onNotice?.(message);
  }

  /**
   * Schedule the next attempt, doubling with jitter and capped.
   *
   * The delay is computed by `reconnectDelay`, which is a pure function so the growth and the cap
   * are testable without waiting for them.
   */
  #scheduleReconnect(): void {
    if (this.#stopped || this.#retryTimer !== null) return;
    this.#attempt += 1;
    const delay = reconnectDelay(this.#attempt);
    this.#retryTimer = setTimeout(() => {
      this.#retryTimer = null;
      void this.#connect();
    }, delay);
  }
}
