import { validateShareSnapshot, type WireShareSnapshot } from "../../../contracts/ts/wire.ts";

/** Static exports use plain text; there is no socket, executable markup or terminal escape parser. */
export function decodePublicShare(locator: string, value: unknown): WireShareSnapshot {
  if (!value || typeof value !== "object") throw new Error("Invalid share");
  const reply = value as { schema_version?: unknown; blocks?: unknown };
  return validateShareSnapshot({
    schema_version: reply.schema_version, snapshot_id: locator,
    styles: [{ fg: { kind: "palette", index: 7 }, bg: { kind: "palette", index: 0 }, flags: 0 }],
    blocks: reply.blocks,
  });
}

export function staticLinkParts(url: URL): { locator: string; secret: string } | null {
  const locator = url.searchParams.get("id");
  const secret = url.hash.slice(1);
  if (!locator || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(locator)
      || !/^[A-Za-z0-9_-]{43}$/.test(secret)) return null;
  return { locator, secret };
}
