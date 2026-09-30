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

import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import type { WireBlock, WireGrid, WireStyle } from "../../../contracts/ts/wire.ts";
import { apiFetch } from "@/lib/api";
import { ViewerConnection } from "./connection.ts";
import { drawGrid, gridText, measureCells, rowText, type CellMetrics } from "./render.ts";
import { initialState, type LiveState, type ViewerState } from "./state.ts";

const API_BASE_URL = process.env.NEXT_PUBLIC_API_BASE_URL ?? "http://127.0.0.1:8081";
const FONT_SIZE = 13;

export function LiveViewer({ sessionId }: { readonly sessionId: string | null }) {
  const [state, setState] = useState<ViewerState>(initialState);
  const [notice, setNotice] = useState<string>("");
  const [focusedBlock, setFocusedBlock] = useState<string | null>(null);

  const requestTicket = useCallback(async (): Promise<string> => {
    if (sessionId === null) throw new Error("no session");
    const response = await apiFetch<{ ticket: string }>(`/live/${sessionId}/tickets`, {
      method: "POST",
      body: { role: "viewer" },
    });
    return response.ticket;
  }, [sessionId]);

  useEffect(() => {
    if (sessionId === null) return;
    const connection = new ViewerConnection({
      apiBaseUrl: API_BASE_URL,
      sessionId,
      requestTicket,
      onState: setState,
      onNotice: setNotice,
    });
    connection.start();
    return () => connection.stop();
  }, [sessionId, requestTicket]);

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

  const live = state.live;

  return (
    <Frame status={statusLabel(state)} notice={notice} live={live}>
      {live === null ? (
        <p className="text-sm text-muted-foreground">
          {state.status === "failed"
            ? "This stream could not be reached. It may have ended, or your session may have expired."
            : "Waiting for the host to send the first snapshot…"}
        </p>
      ) : (
        <Terminal live={live} focused={focusedBlock} onFocusBlock={setFocusedBlock} />
      )}
    </Frame>
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
}: {
  readonly live: LiveState;
  readonly focused: string | null;
  readonly onFocusBlock: (id: string | null) => void;
}) {
  const blocks = live.blocks;
  const focusedBlock = blocks.find((block) => block.id === focused);

  return (
    <div>
      <div
        role="list"
        aria-label="terminal blocks"
        className="divide-y overflow-hidden rounded-lg border"
        onKeyDown={(event) => {
          // Arrow keys move between blocks so a keyboard user can read a long stream without a
          // pointer. Focus is the viewer's, not the host's: nothing here reaches the PTY.
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
    </div>
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
