"use client";

/**
 * The live viewer.
 *
 * Three rendering rules, and each is a decision rather than a style:
 *
 *   * **Canvas for cells, DOM for words.** A grid is pixels; a block's command, its exit code and
 *     every status line are React text nodes. Terminal content therefore has exactly two routes into
 *     the page — pixels, or text — and neither of them is `innerHTML`. A command containing
 *     `<script>` is a row of glyphs.
 *   * **A block is the unit of focus.** Blocks are focusable and the arrow keys move between them,
 *     and the focused block's text is mirrored into one visually-hidden node so a screen reader can
 *     read it. Mirroring every block instead would put two thousand lines into the DOM twice.
 *   * **Reading is not a privilege.** Copy, focus and scroll work with no control lease at all. A
 *     viewer that cannot type is still a viewer that can read, select and copy.
 */

import { useCallback, useEffect, useRef, useState } from "react";

import type { WireBlock, WireGrid, WireInputOperation, WireStyle } from "../../../contracts/ts/wire.ts";
import { currentAccount } from "@/auth/client";
import { ApiError, apiFetch } from "@/lib/api";
import { initialControlState, ViewerConnection, type ControlState } from "./connection.ts";
import { chordFrom, inputOperationFor } from "./keys.ts";
import { drawGrid, gridText, measureCells, rowText, type CellMetrics } from "./render.ts";
import { initialState, type LiveState, type ViewerState } from "./state.ts";

const API_BASE_URL = process.env.NEXT_PUBLIC_API_BASE_URL ?? "/api";
const FONT_SIZE = 13;

export function LiveViewer({ sessionId }: { readonly sessionId: string | null }) {
  const [state, setState] = useState<ViewerState>(initialState);
  const [publicReadOnly, setPublicReadOnly] = useState(false);
  const [accessError, setAccessError] = useState<number | null>(null);
  const [notice, setNotice] = useState<string>("");
  const [focusedBlock, setFocusedBlock] = useState<string | null>(null);
  const [control, setControl] = useState<ControlState>(initialControlState);
  // The connection owns the socket and the lease; the page only reads its state and asks it to act.
  // A ref rather than state, because nothing about it is renderable — a re-render on assign would
  // tear the socket down and build another.
  const connectionRef = useRef<ViewerConnection | null>(null);

  const requestTicket = useCallback(async (): Promise<string> => {
    if (sessionId === null) throw new Error("no session");
    const publicSecret = new URLSearchParams(window.location.hash.slice(1)).get("public");
    try {
      const response = await apiFetch<{ ticket: string }>(`/live/${sessionId}/${publicSecret ? "public-tickets" : "tickets"}`, {
        method: "POST",
        body: publicSecret ? { read_secret: publicSecret } : { role: "viewer" },
      });
      return response.ticket;
    } catch (error) {
      if (error instanceof ApiError && [401, 404, 409].includes(error.status)) {
        setAccessError(publicSecret ? 409 : error.status);
      }
      throw error;
    }
  }, [sessionId]);

  useEffect(() => {
    if (sessionId === null || accessError !== null) return;
    setPublicReadOnly(new URLSearchParams(window.location.hash.slice(1)).has("public"));
    const connection = new ViewerConnection({
      apiBaseUrl: new URL(API_BASE_URL, window.location.origin).toString(),
      sessionId,
      requestTicket,
      onState: setState,
      onNotice: setNotice,
      onControl: setControl,
    });
    connectionRef.current = connection;
    connection.start();
    return () => {
      connection.stop();
      connectionRef.current = null;
    };
  }, [sessionId, requestTicket, accessError]);

  if (sessionId === null) {
    return (
      <Frame status="No session">
        <p className="text-sm text-muted-foreground">
          This link is missing its session. A share link looks like{" "}
          <code className="font-mono">/live/?s=&lt;session-id&gt;</code>.
        </p>
      </Frame>
    );
  }

  if (accessError !== null) {
    return <Frame status="Access required">
      <StreamAccess status={accessError} sessionId={sessionId} onRedeemed={() => {
        setNotice("");
        setAccessError(null);
      }} />
    </Frame>;
  }

  const live = state.live;

  return (
    <Frame status={statusLabel(state)} notice={notice} live={live}>
      {publicReadOnly ? <p className="border-b pb-3 text-sm">Public stream · read-only · temporary link</p> : <ControlBar
        control={control}
        canAsk={live !== null}
        onRequest={() => connectionRef.current?.requestControl()}
        onRelease={() => connectionRef.current?.releaseControl()}
        onPaste={(text) => connectionRef.current?.sendInput({ kind: "paste", text })}
      />}
      {live === null ? (
        <p className="mt-4 text-sm text-muted-foreground">
          {state.status === "failed"
            ? "This stream could not be reached. It may have ended, or your session may have expired."
            : "Waiting for the host to send the first snapshot…"}
        </p>
      ) : (
        <Terminal
          live={live}
          focused={focusedBlock}
          onFocusBlock={setFocusedBlock}
          control={control}
          onKey={(operation) => connectionRef.current?.sendInput(operation) ?? false}
        />
      )}
    </Frame>
  );
}

function StreamAccess({ status, sessionId, onRedeemed }: {
  readonly status: number;
  readonly sessionId: string;
  readonly onRedeemed: () => void;
}) {
  const [accountId, setAccountId] = useState<string | null>(null);
  const [code, setCode] = useState("");
  const [signInHref, setSignInHref] = useState("/sign-in/");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    let cancelled = false;
    setCode(new URLSearchParams(window.location.hash.slice(1)).get("invite") ?? "");
    setSignInHref(`/sign-in/?next=${encodeURIComponent(`/live/?s=${sessionId}${window.location.hash}`)}`);
    if (status === 409) return;
    void currentAccount().then((account) => {
      if (!cancelled) setAccountId(account?.id ?? null);
    });
    return () => { cancelled = true; };
  }, [sessionId, status]);

  async function redeem(event: React.FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError("");
    try {
      const result = await apiFetch<{ session_id: string }>("/live/invitations/redeem", {
        method: "POST", body: { code: code.trim() },
      });
      window.history.replaceState(null, "", `/live/?s=${result.session_id}`);
      if (result.session_id === sessionId) onRedeemed();
      else window.location.assign(`/live/?s=${result.session_id}`);
    } catch (cause) {
      setError(cause instanceof ApiError && cause.status === 401
        ? "Sign in before accepting this invitation."
        : "This invitation is unavailable or belongs to another account. Ask the host for a new one.");
    } finally { setBusy(false); }
  }

  if (status === 409) return <p>This stream has ended or its temporary link has expired. Ask the host for a new share link.</p>;
  if (status === 401) return <p>Sign in to watch this stream. <a className="underline" href={signInHref}>Sign in</a></p>;
  return <div className="max-w-xl space-y-4 text-sm">
    <p>This account does not have access, or the stream is no longer available. Sign in with the Mac’s account, or ask the host for an invitation.</p>
    <p>Anonymous sign-in creates a separate account on each device.</p>
    {accountId && <label className="block space-y-2">
      <span>Send this account ID to the host to enter in Share → Invite a Browser:</span>
      <input aria-label="Your account ID" readOnly value={accountId} onFocus={(event) => event.target.select()} className="w-full rounded border px-3 py-2 font-mono" />
    </label>}
    <form onSubmit={(event) => void redeem(event)} className="space-y-3">
      <label className="block">Invitation code
        <input value={code} onChange={(event) => setCode(event.target.value)} className="mt-2 w-full rounded border px-3 py-2" autoComplete="off" />
      </label>
      <button disabled={busy || !code.trim()} className="rounded border px-3 py-2 disabled:opacity-40">{busy ? "Accepting…" : "Accept invitation"}</button>
      {error && <p role="alert">{error}</p>}
    </form>
    <a href={signInHref} className="underline">Sign in with another account</a>
  </div>;
}

/**
 * The control affordance, and the truth about it.
 *
 * A browser may always *ask*. Nothing is granted by asking: the person in front of the machine
 * approves, and until they do this says so. The state is announced politely rather than assertively,
 * because it changes without the person doing anything.
 */
function ControlBar({
  control,
  canAsk,
  onRequest,
  onRelease,
  onPaste,
}: {
  readonly control: ControlState;
  readonly canAsk: boolean;
  readonly onRequest: () => void;
  readonly onRelease: () => void;
  readonly onPaste: (text: string) => void;
}) {
  const paste = useCallback(async () => {
    try {
      // Read only on a user gesture, and only when it is about to be sent. A viewer that read the
      // clipboard on connect would be doing something the person never asked for.
      onPaste(await navigator.clipboard.readText());
    } catch {
      // A refused clipboard permission is the browser's business, and there is nothing to show.
    }
  }, [onPaste]);

  return (
    <div className="flex flex-wrap items-center gap-3 border-b pb-3" role="status" aria-live="polite">
      {control.status === "granted" ? (
        <>
          <span className="text-sm font-medium">You have control</span>
          <button type="button" onClick={() => void paste()} className="rounded border px-2 py-1 text-xs">
            Paste
          </button>
          <button type="button" onClick={onRelease} className="rounded border px-2 py-1 text-xs">
            Release
          </button>
        </>
      ) : (
        <>
          <button
            type="button"
            onClick={onRequest}
            disabled={!canAsk || control.status === "requesting"}
            className="rounded border px-2 py-1 text-xs disabled:opacity-40"
          >
            {control.status === "requesting" ? "Waiting for the host…" : "Request control"}
          </button>
          {control.status === "denied" ? (
            <span className="text-xs text-muted-foreground">The host declined. You can ask again.</span>
          ) : null}
        </>
      )}
    </div>
  );
}

function statusLabel(state: ViewerState): string {
  switch (state.status) {
    case "idle":
      return "Starting";
    case "connecting":
      return "Connecting";
    case "waiting":
      return "Waiting for the host";
    case "live":
      return "Live";
    case "resyncing":
      return `Resyncing${state.lastRefusal === null ? "" : ` (${state.lastRefusal})`}`;
    case "ended":
      return "Ended";
    case "failed":
      return "Unavailable";
  }
}

function Frame({
  status,
  notice,
  live,
  children,
}: {
  readonly status: string;
  readonly notice?: string;
  readonly live?: LiveState | null;
  readonly children: React.ReactNode;
}) {
  return (
    <div className="mx-auto w-full max-w-5xl px-6 py-8">
      <div className="flex items-center justify-between gap-4 border-b pb-3">
        {/* `role="status"` with a polite live region: the connection state is the one thing a
            screen reader must hear change, and it changes without any user action. */}
        <div role="status" aria-live="polite" className="flex items-center gap-2 text-sm">
          <span
            aria-hidden="true"
            className={`inline-block size-2 rounded-full ${dotClass(status)}`}
          />
          <span className="font-medium">{status}</span>
        </div>
        {notice === undefined || notice === "" ? null : (
          <p className="truncate text-xs text-muted-foreground">{notice}</p>
        )}
      </div>
      {live === null || live === undefined ? null : (
        <p className="mt-3 text-xs text-muted-foreground">
          {live.blocks.length} blocks · {live.columns}×{live.rows} · epoch {live.epoch}
        </p>
      )}
      <div className="mt-4">{children}</div>
    </div>
  );
}

function dotClass(status: string): string {
  if (status === "Live") return "bg-foreground";
  if (status === "Unavailable" || status === "Ended") return "bg-muted-foreground/40";
  return "bg-muted-foreground/70";
}

function Terminal({
  live,
  focused,
  onFocusBlock,
  control,
  onKey,
}: {
  readonly live: LiveState;
  readonly focused: string | null;
  readonly onFocusBlock: (id: string | null) => void;
  readonly control: ControlState;
  readonly onKey: (operation: WireInputOperation) => boolean;
}) {
  const blocks = live.blocks;
  const focusedBlock = blocks.find((block) => block.id === focused);
  const held = control.status === "granted";

  return (
    <div>
      <div
        role="list"
        aria-label="terminal blocks"
        className="divide-y overflow-hidden rounded-lg border"
        onKeyDown={(event) => {
          // Arrow keys move between blocks so a keyboard user can read a long stream without a
          // pointer. Focus is the viewer's, not the host's: nothing here reaches the PTY.
          //
          // While control is held the arrows belong to the terminal instead — a person driving a
          // shell with the arrow keys is moving a cursor, not reading a page, and stealing the keys
          // back would make the prompt unusable.
          if (held) return;
          if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
          const index = blocks.findIndex((block) => block.id === focused);
          const next = event.key === "ArrowDown" ? index + 1 : index - 1;
          const target = blocks[next];
          if (target === undefined) return;
          event.preventDefault();
          onFocusBlock(target.id);
          document.getElementById(`block-${target.id}`)?.focus();
        }}
      >
        {blocks.map((block) => (
          <BlockView
            key={block.id}
            block={block}
            styles={live.styles}
            columns={live.columns}
            onFocus={() => onFocusBlock(block.id)}
          />
        ))}
      </div>

      {/* One hidden mirror of the focused block, rather than two thousand lines twice. */}
      <pre className="sr-only" aria-live="polite">
        {focusedBlock === undefined
          ? ""
          : `block ${focusedBlock.id}, command ${focusedBlock.command}\n${gridText(focusedBlock.output)}`}
      </pre>

      <InputFunnel held={held} onKey={onKey} />
    </div>
  );
}

/**
 * Where a browser's keystrokes become the contract's input union.
 *
 * A real text area rather than a focus trap on the blocks, because the two things a terminal needs
 * and a `keydown` handler cannot provide both come from the input system: composed text — an IME
 * candidate, a dead key, an accented character — arrives as an `input` event, and the contract's
 * `text` operation is defined as exactly that, "an IME committed insertion, never a keyboard-layout
 * guess". Named keys and chords arrive as `keydown` and never produce an `input` event, so the two
 * paths cannot double-send.
 *
 * The value is cleared on every event and never read back: this is a funnel, not a buffer, and a
 * buffer would show the person their own keystrokes twice.
 */
function InputFunnel({
  held,
  onKey,
}: {
  readonly held: boolean;
  readonly onKey: (operation: WireInputOperation) => boolean;
}) {
  const ref = useRef<HTMLTextAreaElement | null>(null);

  // Focus follows the lease. Holding control and then having to click into a box before typing is
  // the kind of small friction that makes a feature feel broken.
  useEffect(() => {
    if (held) ref.current?.focus();
  }, [held]);

  const handleKeyDown = useCallback(
    (event: React.KeyboardEvent<HTMLTextAreaElement>) => {
      if (!held) return;
      const operation = inputOperationFor(chordFrom(event.nativeEvent));
      if (operation === null) return;
      // Prevented for everything the funnel handles, which is also what stops the text area from
      // producing an `input` event for the same keystroke.
      event.preventDefault();
      onKey(operation);
    },
    [held, onKey],
  );

  const handleChange = useCallback(
    (event: React.ChangeEvent<HTMLTextAreaElement>) => {
      const text = event.target.value;
      event.target.value = "";
      if (!held || text === "") return;
      onKey({ kind: "text", text });
    },
    [held, onKey],
  );

  if (!held) {
    return (
      <p className="mt-3 rounded-lg border border-dashed px-4 py-3 text-xs text-muted-foreground">
        You are watching. Ask for control to type.
      </p>
    );
  }

  return (
    <textarea
      ref={ref}
      defaultValue=""
      onChange={handleChange}
      onKeyDown={handleKeyDown}
      rows={1}
      spellCheck={false}
      autoComplete="off"
      autoCorrect="off"
      autoCapitalize="off"
      aria-label="Terminal input. Your keystrokes are sent to the host while you hold control."
      placeholder="Type here — your keystrokes go to the host's terminal."
      className="mt-3 w-full resize-none rounded-lg border bg-transparent px-4 py-3 font-mono text-sm outline-none focus-visible:border-foreground/40"
    />
  );
}

function BlockView({
  block,
  styles,
  columns,
  onFocus,
}: {
  readonly block: WireBlock;
  readonly styles: readonly WireStyle[];
  readonly columns: number;
  readonly onFocus: () => void;
}) {
  const [copied, setCopied] = useState(false);

  const copy = useCallback(async () => {
    // Local copy needs no control rights and never leaves the browser.
    try {
      await navigator.clipboard.writeText(gridText(block.output));
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // A denied clipboard permission is the browser's business; the text is still selectable.
    }
  }, [block.output]);

  return (
    <div
      id={`block-${block.id}`}
      role="listitem"
      tabIndex={0}
      onFocus={onFocus}
      className="group px-4 py-3 outline-none focus-visible:bg-muted/50"
    >
      <div className="flex items-baseline justify-between gap-4">
        <div className="flex min-w-0 items-baseline gap-2">
          <span aria-hidden="true" className="font-mono text-xs text-muted-foreground">
            {promptFor(block.state)}
          </span>
          {/* Text, not HTML. A command is data. */}
          <span className="truncate font-mono text-sm">{block.command}</span>
        </div>
        <div className="flex shrink-0 items-baseline gap-3 text-xs text-muted-foreground">
          {block.exit_code === undefined ? null : (
            <span>{block.exit_code === 0 ? "ok" : `exit ${block.exit_code}`}</span>
          )}
          {block.duration_ms === undefined ? null : <span>{formatDuration(block.duration_ms)}</span>}
          <button
            type="button"
            onClick={() => void copy()}
            className="rounded border px-1.5 py-0.5 opacity-0 transition-opacity focus-visible:opacity-100 group-hover:opacity-100"
          >
            {copied ? "Copied" : "Copy"}
          </button>
        </div>
      </div>

      {block.collapsed ? null : (
        <div className="mt-2 space-y-1">
          <GridCanvas grid={block.header} styles={styles} columns={columns} label="command" />
          <GridCanvas
            grid={block.output}
            styles={styles}
            columns={columns}
            label={`output of ${block.command}`}
          />
        </div>
      )}
    </div>
  );
}

function GridCanvas({
  grid,
  styles,
  columns,
  label,
}: {
  readonly grid: WireGrid;
  readonly styles: readonly WireStyle[];
  readonly columns: number;
  readonly label: string;
}) {
  const ref = useRef<HTMLCanvasElement | null>(null);
  const metricsRef = useRef<CellMetrics | null>(null);

  useEffect(() => {
    const canvas = ref.current;
    if (canvas === null) return;

    const paint = () => {
      const ctx = canvas.getContext("2d");
      if (ctx === null) return;
      // The font comes from the stylesheet, not from a literal, so the canvas and the DOM use the
      // same face and a font change is one edit.
      const fontFamily = getComputedStyle(canvas).fontFamily || "monospace";
      metricsRef.current ??= measureCells(ctx, fontFamily, FONT_SIZE);
      drawGrid(canvas, grid, {
        styles,
        fontFamily,
        fontSize: FONT_SIZE,
        metrics: metricsRef.current,
        cursorVisible: true,
      });
    };

    paint();

    // Redraw on a device-pixel-ratio change, which happens when a window moves between displays.
    // Without this the canvas keeps the old backing-store scale and goes soft.
    const media = window.matchMedia(`(resolution: ${devicePixelRatio}dppx)`);
    media.addEventListener("change", paint);
    return () => media.removeEventListener("change", paint);
  }, [grid, styles, columns]);

  // The canvas is a picture of text, so it is described rather than duplicated. The readable copy
  // is the hidden mirror above, and the Copy button.
  return (
    <canvas
      ref={ref}
      className="terminal-cell block max-w-full"
      role="img"
      aria-label={`${label}, ${grid.lines.length} lines`}
      title={grid.lines.map(rowText).join("\n")}
    />
  );
}

function promptFor(state: WireBlock["state"]): string {
  switch (state) {
    case "draft":
      return ">";
    case "running":
      return "…";
    case "sealed":
      return "$";
  }
}

function formatDuration(ms: number): string {
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
  return `${Math.round(ms / 60_000)}m`;
}

/** Re-exported so the route can render a placeholder without importing the reducer. */
export { initialState as emptyViewerState };
export type { ViewerState };
