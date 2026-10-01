"use client";

import { useEffect, useState } from "react";
import type { WireShareSnapshot } from "../../../contracts/ts/wire.ts";
import { decodePublicShare, staticLinkParts } from "./static";

export function StaticShareViewer() {
  const [snapshot, setSnapshot] = useState<WireShareSnapshot | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    const parts = staticLinkParts(new URL(window.location.href));
    if (!parts) { setError("This share link is incomplete."); return; }
    const controller = new AbortController();
    void fetch(`${process.env.NEXT_PUBLIC_API_BASE_URL ?? "/api"}/shares/resolve`, {
      method: "POST", credentials: "omit", cache: "no-store", signal: controller.signal,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ locator: parts.locator, read_secret: parts.secret }),
    }).then(async (response) => {
      if (!response.ok) throw new Error("Unavailable");
      const document = decodePublicShare(parts.locator, await response.json());
      if (!controller.signal.aborted) setSnapshot(document);
    }).catch(() => {
      if (!controller.signal.aborted) setError("This share is unavailable. It may have been revoked or expired.");
    });
    return () => controller.abort();
  }, []);

  return <section className="mx-auto w-full max-w-5xl px-6 py-10">
    <h1 className="text-2xl font-medium">Terminal snapshot</h1>
    <p className="mt-2 text-sm text-muted-foreground">Public, read-only snapshot. The host’s terminal is not connected.</p>
    {error ? <p role="alert" className="mt-6">{error}</p> : !snapshot ? <p role="status" className="mt-6">Loading snapshot…</p> :
      <div className="mt-6 space-y-6">{snapshot.blocks.map((block) => <article key={block.id} className="overflow-hidden rounded-lg border">
        <header className="border-b px-4 py-3">
          <code className="whitespace-pre-wrap break-all">{block.command}</code>
          {block.exit_code !== undefined && <span className="ml-3 text-xs text-muted-foreground">Exit {block.exit_code}</span>}
        </header>
        <pre className="overflow-x-auto bg-[#171717] p-4 text-sm text-[#eeeeee]"><code>{block.lines.map((line) => line.text).join("\n")}</code></pre>
      </article>)}</div>}
  </section>;
}
